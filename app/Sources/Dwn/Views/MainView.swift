import SwiftUI
import UniformTypeIdentifiers

/// Splash while the engine starts, then first-run setup or the main window.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var engine: Engine
    @Local private var minTimeDone = false

    private var engineReady: Bool { if case .running = engine.state { return true } else { return false } }
    private var failure: String? { if case .failed(let m) = engine.state { return m } else { return nil } }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !(engineReady && minTimeDone) {
                SplashView(status: "Starting the engine", failed: failure,
                           onRetry: { engine.restart() },
                           onShowLog: { NSWorkspace.shared.activateFileViewerSelecting([Engine.logURL]) })
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            } else if !model.onboarded {
                WelcomeView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .overlay(alignment: .bottom) { ToastStack() }
        .animation(.easeInOut(duration: 0.5), value: engineReady && minTimeDone)
        .animation(.easeInOut(duration: 0.5), value: model.onboarded)
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        .task {
            try? await Task.sleep(for: .seconds(1.9))
            minTimeDone = true
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Local private var dropHover = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 368)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            DownloadsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button { model.openFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 32, filled: true)).help("Open download folder")
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle(size: 32, filled: true)).help("Settings")
            }
            .padding(.top, 12).padding(.trailing, 14)
            .ignoresSafeArea()
        }
        .overlay {
            if dropHover {
                ZStack {
                    Theme.bg.opacity(0.75)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .padding(14)
                    VStack(spacing: 14) {
                        DropArrow().fill(Theme.accent).frame(width: 30, height: 44)
                        Text("Drop to download").font(.ui(20, .bold)).foregroundStyle(Theme.text)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropHover)
        .onDrop(of: [.url, .plainText, .fileURL], isTargeted: $dropHover) { handleDrop($0) }
        .sheet(isPresented: $model.showBulk) { BulkView(prefill: model.bulkPrefill) }
        .sheet(isPresented: $model.showSignIn) { SignInSheet() }
        .modifier(UpdateSheetHost(updater: model.updater))
        .sheet(item: Binding(get: { model.sectionTarget.map(SectionTarget.init) },
                             set: { model.sectionTarget = $0?.info })) { t in
            SectionEditorView(info: t.info).background(Theme.sidebar)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                    Task { @MainActor in model.bulkPrefill = text; model.showBulk = true }
                }
                return true
            }
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, !url.isFileURL else { return }
                    Task { @MainActor in model.composerText = url.absoluteString }
                }
                return true
            }
            if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in
                        let lines = s.split(whereSeparator: \.isNewline).map(String.init).filter(looksLikeLink)
                        if lines.count > 1 { model.bulkPrefill = s; model.showBulk = true }
                        else if looksLikeLink(s) { model.composerText = s }
                    }
                }
                return true
            }
        }
        return false
    }
}

struct SectionTarget: Identifiable {
    var info: LinkInfo
    var id: String { info.url ?? "" }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ComposerView()
                    BulkCard()
                }
                .padding(.top, 40)
                .padding(.horizontal, 14)
            }
            Footer().padding(.horizontal, 20).padding(.bottom, 14)
        }
    }
}

struct BulkCard: View {
    @EnvironmentObject var model: AppModel
    @Local private var hover = false

    var body: some View {
        Button { model.showBulk = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(.ui(15, .medium)).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bulk download").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text("Download several links at once").font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Text("⌘B").font(.ui(11.5, .medium)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .card(hover ? Theme.raised : Theme.card, radius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct Footer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.chooseFolder() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").frame(width: M.iconColumn)
                    Text("Saving to").foregroundStyle(Theme.text3)
                    Text((model.prefs.folder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .help("Change where files are saved")
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").frame(width: M.iconColumn)
                Text([model.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free" },
                      model.health.map { "yt-dlp " + $0.ytdlp }].compactMap { $0 }.joined(separator: " · "))
            }
            .foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                Wordmark(size: 12, color: Theme.text3, arrowColor: Theme.text3)
                Text("v" + model.updater.current).foregroundStyle(Theme.text3.opacity(0.7))
                Spacer()
                UpdatePill(updater: model.updater)
            }
            .padding(.top, 2)
        }
        .font(.ui(11.5))
        .foregroundStyle(Theme.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToastStack: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.toasts) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? Theme.warn : Theme.accent)
                    Text(t.text).font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(3)
                    if t.isError {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(Theme.text2)
                            .help("Copy Error Details")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Capsule().fill(Theme.raised))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 20)
        .animation(.spring(duration: 0.3), value: model.toasts)
    }
}

/// Presents the update sheet when the updater asks for it.
struct UpdateSheetHost: ViewModifier {
    @ObservedObject var updater: Updater
    func body(content: Content) -> some View {
        content.sheet(isPresented: $updater.showSheet) { UpdateSheet(updater: updater) }
    }
}
