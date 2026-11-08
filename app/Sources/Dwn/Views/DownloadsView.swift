import Quartz
import SwiftUI

/// Right pane: what's downloading now, then everything downloaded before.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @Local private var query = ""
    @Local private var confirmStop = false

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.history }
        let words = q.split(separator: " ")
        return model.history.filter { h in
            let hay = ((h.title ?? "") + " " + h.url + " " + Formats.name(h.format ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private var isEmpty: Bool { model.activeJobs.isEmpty && model.history.isEmpty }
    private var signInFailures: Bool { model.jobs.contains { $0.errorCode == "signin" && $0.state == "failed" } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.35), Theme.bg], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                .ignoresSafeArea()
            if !model.historyLoaded {
                ProgressView().controlSize(.small)
            } else if isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    topBar
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if signInFailures { signInBanner }
                            if !model.activeJobs.isEmpty {
                                sectionHeader("In progress", trailing: stopAll)
                                ForEach(model.activeJobs) { JobCard(job: $0) }
                                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.activeJobs.map(\.id))
                            }
                            if !model.history.isEmpty {
                                sectionHeader(query.isEmpty ? "Downloads" : "\(filtered.count) matching", trailing: EmptyView())
                                    .padding(.top, model.activeJobs.isEmpty ? 0 : 14)
                                if filtered.isEmpty {
                                    Text("Nothing matches “\(query)”").font(.ui(13)).foregroundStyle(Theme.text3)
                                        .padding(.vertical, 30).frame(maxWidth: .infinity)
                                }
                                ForEach(filtered) { HistoryRow(item: $0) }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 30)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            LogoMark(size: 64)
            VStack(spacing: 7) {
                Text("Nothing downloaded yet").font(.ui(18, .bold)).foregroundStyle(Theme.text)
                Text("Paste a link on the left, or drop one\nanywhere in the window.")
                    .font(.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                ForEach(model.shortcut.symbols, id: \.self) { keycap($0) }
                Text(model.shortcutAction == "instant" ? "downloads the copied link from any app"
                     : "opens quick download from any app").font(.ui(12)).foregroundStyle(Theme.text3)
            }
            .padding(.top, 6)
        }
    }

    private func keycap(_ k: String) -> some View {
        Text(k).font(.ui(11.5, .semibold)).foregroundStyle(Theme.text2)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.strokeStrong))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("", text: $query, prompt: Text("Search downloads").foregroundStyle(Theme.text3))
                    .textFieldStyle(.plain).font(.ui(13.5)).foregroundStyle(Theme.text)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 280, height: 34)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            Spacer()
        }
        .padding(.leading, 22)
        .padding(.trailing, 110)
        .padding(.top, 12)
        .frame(height: 64, alignment: .top)
    }

    private func sectionHeader<T: View>(_ t: String, trailing: T) -> some View {
        HStack {
            Text(t).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text3).textCase(.uppercase).tracking(0.6)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    @ViewBuilder private var stopAll: some View {
        let running = model.jobs.filter(\.isActive).count
        if running > 1 {
            Button("Stop all") { confirmStop = true }
                .buttonStyle(.plain).font(.ui(12.5, .medium)).foregroundStyle(Theme.text2)
                .confirmationDialog("Stop everything?", isPresented: $confirmStop) {
                    Button("Stop \(running) downloads", role: .destructive) { model.cancelAll() }
                }
        }
    }

    private var signInBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.badge.key.fill").font(.ui(20)).foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube wants to check you're a real person").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                Text("Sign in with your browser and Dwn will retry those downloads.")
                    .font(.ui(12.5)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button("Sign in") { model.showSignIn = true }.buttonStyle(PrimaryButtonStyle(height: 34)).frame(width: 96)
        }
        .padding(16)
        .card(Theme.warn.opacity(0.08), radius: 16)
        .padding(.bottom, 10)
    }
}

struct JobCard: View {
    @EnvironmentObject var model: AppModel
    var job: Job

    var body: some View {
        HStack(spacing: 14) {
            Thumb(url: job.thumbnail).frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title).font(.ui(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                switch job.state {
                case "failed":
                    Text(job.error ?? "Couldn't download").font(.ui(12)).foregroundStyle(Theme.warn)
                        .lineLimit(3).textSelection(.enabled)
                case "cancelled":
                    Text("Stopped").font(.ui(12)).foregroundStyle(Theme.text3)
                default:
                    ProgressBar(value: job.progress, indeterminate: job.state == "queued" || (job.progress <= 0 && job.state != "converting"))
                    HStack(spacing: 6) {
                        Text(job.stage)
                        if let s = job.speed, job.state == "running" { Text("· \(formatBytes(s))/s") }
                        if let e = job.eta, job.state == "running", e > 0 { Text("· \(Time.format(e)) left") }
                        Spacer()
                        Text(badge).foregroundStyle(Theme.text3)
                    }
                    .font(.ui(11.5)).foregroundStyle(Theme.text2)
                }
            }
            HStack(spacing: 6) {
                if job.isActive {
                    Button { model.cancel(job) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Stop downloading")
                } else {
                    if job.errorCode == "signin" {
                        Button("Sign in") { model.showSignIn = true }.buttonStyle(QuietButtonStyle(height: 30))
                    }
                    Button { model.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Try again")
                    Button { model.dismiss(job) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Remove from List")
                }
            }
        }
        .padding(12)
        .card(Theme.card, radius: 16)
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
    }

    private var badge: String {
        var s = Formats.name(job.format)
        if job.mode == "instrumental" { s = "Instrumental · " + s }
        if job.start != nil || job.end != nil { s += " · " + Time.format(job.start ?? 0) + "–" + Time.format(job.end) }
        return s
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    var item: HistoryItem
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Thumb(url: item.thumbnail)
                .frame(width: 80, height: 45)
                .opacity(item.exists == false ? 0.35 : 1)
                .overlay {
                    if item.kind == "audio" {
                        Image(systemName: "waveform").font(.ui(13, .bold)).foregroundStyle(.white)
                            .padding(5).background(Circle().fill(.black.opacity(0.55)))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.url).font(.ui(13.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formats.name(item.format ?? "")).font(.ui(10.5, .semibold)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.raised))
                    if item.start != nil || item.end != nil {
                        Text("Section " + Time.format(item.start ?? 0) + "–" + Time.format(item.end))
                    }
                    if let f = item.finished {
                        Text(Date(timeIntervalSince1970: f).formatted(.relative(presentation: .named)))
                    }
                    if item.exists == false { Text("· File moved or deleted").foregroundStyle(Theme.warn) }
                }
                .font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)
            if hover && item.exists != false {
                HStack(spacing: 6) {
                    Button { QuickLooker.shared.show([URL(fileURLWithPath: item.file ?? "")]) } label: { Image(systemName: "eye") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Quick Look")
                    Button { model.reveal(item.file) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Show in Finder")
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onTapGesture(count: 2) { model.open(item.file) }
        .contextMenu {
            Button("Open") { model.open(item.file) }
            Button("Show in Finder") { model.reveal(item.file) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Button("Download Again") { Task { await model.download(item.url) } }
            Divider()
            Button("Remove from List") { model.forget([item.id]) }
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        }
    }
}

/// Quick Look panel driver.
final class QuickLooker: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLooker()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}
