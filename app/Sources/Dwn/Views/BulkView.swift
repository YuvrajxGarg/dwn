import SwiftUI
import UniformTypeIdentifiers

/// Paste many links (or a text/CSV file), expand playlists, review, then queue them all.
struct BulkView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var prefill: String
    @Local private var text = ""
    @Local private var reviewing = false
    @Local private var busy = false
    @Local private var items: [BulkItem] = []
    @Local private var skipped: [String] = []
    @Local private var chosen = Set<String>()
    @Local private var skipExisting = true
    @Local private var kind = "video"
    @Local private var error: String?
    @Local private var importing = false

    private struct StartResult: Decodable { var queued: [Job] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bulk download").font(.ui(20, .bold)).foregroundStyle(Theme.text)
                Spacer()
                if reviewing { Button("Back") { reviewing = false } }
            }
            if reviewing { reviewStep } else { pasteStep }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())
                if reviewing {
                    Button("Start downloading \(selected.count)") { Task { await startAll() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle(height: 36)).frame(width: 220)
                        .disabled(selected.isEmpty || busy)
                } else {
                    Button { Task { await review() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Review") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle(height: 36)).frame(width: 120)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: 540)
        .background(Theme.sidebar)
        .onAppear {
            text = prefill
            kind = model.prefs.kind
            model.bulkPrefill = ""
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .commaSeparatedText, .text]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 5_000_000 { error = "That file is too big. 5 MB max."; return }
            if let s = try? String(contentsOf: url, encoding: .utf8) { text += (text.isEmpty ? "" : "\n") + s }
            else { error = "Couldn't read that file." }
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste links, one per line. Playlists, albums and channels expand on their own.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .card(Theme.card, radius: 12)
            HStack {
                Button("Paste from clipboard") {
                    text += (text.isEmpty ? "" : "\n") + (NSPasteboard.general.string(forType: .string) ?? "")
                }
                Button("Add a text or CSV file…") { importing = true }
            }
        }
    }

    private var selected: [BulkItem] {
        items.filter { chosen.contains($0.id) && $0.error == nil && !(skipExisting && $0.downloaded == true) }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $kind) {
                    Text("Video · \(Formats.name(model.prefs.videoFormat))").tag("video")
                    Text("Audio · \(Formats.name(model.prefs.audioFormat))").tag("audio")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                Spacer()
                Toggle("Skip links already downloaded", isOn: $skipExisting)
            }
            List(items) { it in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { chosen.contains(it.id) },
                                             set: { v in if v { chosen.insert(it.id) } else { chosen.remove(it.id) } }))
                        .labelsHidden()
                        .disabled(it.error != nil)
                    Thumb(url: it.thumbnail).frame(width: 48, height: 27)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.title ?? it.url ?? "").lineLimit(1)
                        HStack(spacing: 6) {
                            if let p = it.playlist { Text(p) }
                            if let d = it.duration { Text(Time.format(d)) }
                            if it.downloaded == true { Text("Already downloaded") }
                            if let e = it.error { Text(e).foregroundStyle(.orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .listStyle(.bordered)
            if !skipped.isEmpty {
                DisclosureGroup("Skipped \(skipped.count) lines with no link") {
                    Text(skipped.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private func review() async {
        error = nil
        busy = true
        defer { busy = false }
        guard let api = model.api else { return }
        do {
            let r: BulkExpand = try await api.call("bulk/expand", ["text": text, "limit": 500])
            if r.items.isEmpty {
                error = "Nothing to download. Check the list and try again."
                return
            }
            items = r.items
            skipped = r.skipped
            chosen = Set(r.items.filter { $0.error == nil }.map(\.id))
            reviewing = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startAll() async {
        busy = true
        defer { busy = false }
        guard let api = model.api else { return }
        let list: [[String: String]] = selected.map {
            ["url": $0.url ?? "", "title": $0.title ?? "", "thumbnail": $0.thumbnail ?? ""]
        }
        do {
            let r: StartResult = try await api.call("bulk/start", [
                "items": list, "kind": kind,
                "format": kind == "video" ? model.prefs.videoFormat : model.prefs.audioFormat,
            ])
            await model.refreshJobs()
            model.toast("Queued \(r.queued.count) downloads")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
