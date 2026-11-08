import SwiftUI

/// Small lime pill in the sidebar footer when a newer version exists.
struct UpdatePill: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.hasUpdate, let v = updater.latest?.version {
            Button { updater.showSheet = true } label: {
                HStack(spacing: 6) {
                    if case .downloading(let p) = updater.phase {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).tint(.black)
                        Text("Updating… \(Int(p * 100))%")
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(v)")
                    }
                }
                .font(.ui(11.5, .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// What's new + Update now.
struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LogoMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dwn \(updater.latest?.version ?? "") is available").font(.ui(18, .bold)).foregroundStyle(Theme.text)
                    Text("You have \(updater.current).").font(.ui(12.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            if let notes = updater.latest?.notes, !notes.isEmpty {
                ScrollView {
                    Text(LocalizedStringKey(notes))
                        .font(.ui(12.5)).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            }
            status
            HStack {
                if let page = updater.latest?.page {
                    Link("Release page", destination: page).font(.ui(12.5, .medium)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Button("Later") { dismiss() }.buttonStyle(QuietButtonStyle(height: 36)).keyboardShortcut(.cancelAction)
                Button { Task { await updater.install() } } label: {
                    Label("Update and restart", systemImage: "arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle(height: 36))
                .frame(width: 200)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.sidebar)
    }

    private var busy: Bool {
        switch updater.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(value: p)
                Text("Downloading the update… \(Int(p * 100))%").font(.ui(12)).foregroundStyle(Theme.text3)
            }
        case .installing:
            Label("Installing. Dwn will reopen in a moment.", systemImage: "gearshape.2").font(.ui(12.5)).foregroundStyle(Theme.text2)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").font(.ui(12.5)).foregroundStyle(Theme.warn)
        default:
            EmptyView()
        }
    }
}

/// Settings tab: version, check now, automatic checks.
struct UpdateSettings: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: updater.current)
                LabeledContent("Status") { statusText }
                if let d = updater.lastChecked {
                    LabeledContent("Last checked", value: d.formatted(.relative(presentation: .named)))
                }
                HStack {
                    Button(updater.phase == .checking ? "Checking…" : "Check for Updates") {
                        Task { await updater.check(manual: true) }
                    }
                    .disabled(updater.phase == .checking)
                    if updater.hasUpdate {
                        Button("Update to \(updater.latest?.version ?? "")") { updater.showSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updater.autoCheck)
                Text("Dwn checks GitHub for new releases when it opens and every few hours, and lets you know when one is ready.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("All releases on GitHub", destination: URL(string: "https://github.com/\(updater.repo)/releases")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusText: some View {
        switch updater.phase {
        case .idle: Text("Not checked yet").foregroundStyle(.secondary)
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
        case .available: Text("Version \(updater.latest?.version ?? "") is available").foregroundStyle(Theme.accent)
        case .downloading(let p): Text("Downloading \(Int(p * 100))%").foregroundStyle(.secondary)
        case .installing: Text("Installing…").foregroundStyle(.secondary)
        case .failed(let m): Text(m).foregroundStyle(Theme.warn)
        }
    }
}
