import AppKit
import Combine
import SwiftUI

/// A borderless floating panel that can take keyboard focus without
/// activating Dwn, so the app you were in stays frontmost.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the quick-download panel that slides up in the bottom-right corner.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var panel: FloatingPanel?
    private var anchor: NSPoint = .zero      // the corner the panel sticks to
    private var top = true                    // true: top-right under the menu bar; false: bottom-right
    private(set) var isShown = false
    let willShow = PassthroughSubject<Void, Never>()

    init(model: AppModel) {
        self.model = model
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 420),
                              styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self

        let host = NSHostingController(rootView: QuickPanelView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        p.contentViewController = host
        return p
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        willShow.send()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        top = model.panelPosition != "bottom"
        anchor = top ? NSPoint(x: vf.maxX - 12, y: vf.maxY - 10) : NSPoint(x: vf.maxX - 18, y: vf.minY + 18)
        p.layoutIfNeeded()
        place(p, yOffset: top ? 14 : -14)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        isShown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(origin(for: p.frame.size, yOffset: 0))
        }
    }

    func hide() {
        guard let p = panel, isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 0
            p.animator().setFrameOrigin(origin(for: p.frame.size, yOffset: self.top ? 10 : -10))
        }, completionHandler: {
            Task { @MainActor in if !self.isShown { p.orderOut(nil) } }
        })
    }

    // AppKit's y axis points up, so a top anchor subtracts the panel's height.
    private func origin(for size: NSSize, yOffset: CGFloat) -> NSPoint {
        NSPoint(x: anchor.x - size.width, y: (top ? anchor.y - size.height : anchor.y) + yOffset)
    }

    private func place(_ p: NSPanel, yOffset: CGFloat) {
        p.setFrameOrigin(origin(for: p.frame.size, yOffset: yOffset))
    }

    // Keep the anchored corner pinned while SwiftUI grows or shrinks the panel.
    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor in
            guard let p = self.panel, self.isShown else { return }
            self.place(p, yOffset: 0)
        }
    }

    // Clicking anywhere else dismisses the panel.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard let p = self.panel, !p.isKeyWindow, NSApp.modalWindow == nil else { return }
            // Menus (dropdowns) attached to the panel don't count as leaving it.
            if NSApp.windows.contains(where: { $0.isVisible && $0.level.rawValue > p.level.rawValue && $0.className.contains("Menu") }) { return }
            self.hide()
        }
    }
}

/// Compact composer shown in the floating panel.
struct QuickPanelView: View {
    @EnvironmentObject var model: AppModel
    @Local private var text = ""
    @Local private var info: LinkInfo?
    @Local private var looking = false
    @Local private var lookupError: String?
    @Local private var justStarted = false
    @FocusState private var focused: Bool

    private var link: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { looksLikeLink(link) }
    private let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            field
            preview
            DwnTabs(items: [
                TabItem(id: "video", title: "Video", icon: "film"),
                TabItem(id: "audio", title: "Audio", icon: "waveform"),
                TabItem(id: "transcript", title: "Transcript", icon: "text.alignleft"),
            ], selection: $model.tab)
            formatPicker
            if model.tab != "transcript" { tiles }
            actions
            if !model.jobs.filter(\.isActive).isEmpty { activeList }
        }
        .padding(14)
        .frame(width: width)
        .background {
            ZStack {
                VisualEffect()
                Theme.sidebar.opacity(0.86)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(model.quickPanel.willShow) { _ in prefill() }
        .onAppear { prefill() }
        .task(id: link) { await lookup() }
        .onExitCommand { model.quickPanel.hide() }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: model.tab)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: info)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: looking)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: model.jobs.filter(\.isActive).map(\.id))
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 2) {
            Wordmark(size: 15)
                .padding(.leading, 2)
            Spacer()
            Button { model.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(IconButtonStyle(size: 26)).help("Open Dwn")
            Button { model.quickPanel.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 26)).help("Close (Esc)")
        }
        .frame(height: 26)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3)
                .frame(width: M.iconColumn)
            TextField("", text: $text, prompt: Text("Paste a link").foregroundStyle(Theme.text3))
                .textFieldStyle(.plain).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { Task { await start() } }
            if text.isEmpty {
                Button("Paste") {
                    text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                .buttonStyle(.plain).font(.ui(12, .semibold)).foregroundStyle(Theme.text2)
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.ui(12.5)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: M.control)
        .controlFill()
        .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.16 : 0)))
    }

    @ViewBuilder private var preview: some View {
        if justStarted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text("Download started").foregroundStyle(Theme.text)
            }
            .font(.ui(12.5, .medium))
            .padding(.horizontal, 2)
            .transition(.opacity)
        } else if !link.isEmpty && !valid {
            Text("That doesn't look like a link.").font(.ui(12)).foregroundStyle(Theme.warn).padding(.horizontal, 2)
        } else if looking && info == nil {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)).frame(width: 56, height: 32).overlay(Shimmer())
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(height: 8).overlay(Shimmer()).clipShape(Capsule())
                    Capsule().fill(Color.white.opacity(0.06)).frame(width: 90, height: 6).overlay(Shimmer()).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 2)
        } else if let lookupError {
            Text(lookupError).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(2).padding(.horizontal, 2)
        } else if let info {
            HStack(spacing: 10) {
                Thumb(url: info.thumbnail).frame(width: 56, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    if let title = info.title {
                        Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    } else {
                        Capsule().fill(Color.white.opacity(0.08)).frame(width: 160, height: 9).overlay(Shimmer()).clipShape(Capsule())
                    }
                    Text([info.uploader,
                          info.isPlaylist == true ? "\(info.count ?? 0) items" : info.duration.map { Time.format($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var formatPicker: some View {
        switch model.tab {
        case "video":
            DwnDropdown(options: Formats.heights.map { ($0.0, $0.1, codecShort) },
                        selection: Binding(get: { model.prefs.maxHeight }, set: { v in model.updatePrefs { $0.maxHeight = v } }),
                        icon: "aspectratio")
        case "audio":
            DwnDropdown(options: Formats.audio.map { ($0.id, $0.name, nil) },
                        selection: Binding(get: { model.prefs.audioFormat }, set: { v in model.updatePrefs { $0.audioFormat = v } }),
                        icon: "music.note")
        default:
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3)
                    .frame(width: M.iconColumn)
                Text("Saves the captions as a text file").font(.ui(12.5)).foregroundStyle(Theme.text2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: M.control)
            .controlFill()
        }
    }

    private var codecShort: String {
        ["h264": "H.264", "hevc": "HEVC", "prores": "ProRes", "original": "Original"][model.prefs.videoFormat] ?? ""
    }

    private var tiles: some View {
        HStack(spacing: 6) {
            OptionTile(icon: "photo", title: "Cover", isOn: pref(\.embedThumbnail))
            OptionTile(icon: "tag", title: "Metadata", isOn: pref(\.embedMetadata))
            if model.tab == "video" {
                OptionTile(icon: "captions.bubble", title: "Subtitles", isOn: pref(\.embedSubs))
                OptionTile(icon: "film.stack", title: "ProRes", isOn: Binding(
                    get: { model.prefs.videoFormat == "prores" },
                    set: { on in
                        if on {
                            UserDefaults.standard.set(model.prefs.videoFormat, forKey: "codecBeforeProRes")
                            model.updatePrefs { $0.videoFormat = "prores" }
                        } else {
                            let prev = UserDefaults.standard.string(forKey: "codecBeforeProRes") ?? "h264"
                            model.updatePrefs { $0.videoFormat = prev == "prores" ? "h264" : prev }
                        }
                    }))
            }
            OptionTile(icon: "key", title: "Login", isOn: Binding(
                get: { !model.prefs.browserCookies.isEmpty },
                set: { on in
                    if on { model.showMainWindow(); model.showSignIn = true }
                    else { model.updatePrefs { $0.browserCookies = "" } }
                }))
        }
    }

    private func pref(_ kp: WritableKeyPath<Prefs, Bool>) -> Binding<Bool> {
        Binding(get: { model.prefs[keyPath: kp] }, set: { v in model.updatePrefs { $0[keyPath: kp] = v } })
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { Task { await start() } } label: {
                Label(model.tab == "transcript" ? "Save transcript"
                      : (info?.isPlaylist == true ? "Download all \(info?.count ?? 0)" : "Download"),
                      systemImage: model.tab == "transcript" ? "text.alignleft" : "arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle(height: 38))
            .keyboardShortcut(.defaultAction)
            .disabled(!valid)
            if model.tab != "transcript" {
                Button {
                    model.sectionTarget = info ?? LinkInfo(url: normalizeLink(link))
                    model.showMainWindow()
                } label: { Image(systemName: "scissors") }
                    .buttonStyle(IconButtonStyle(size: 38, filled: true))
                    .help("Download just a section (opens Dwn)")
                    .disabled(!valid || info?.isPlaylist == true)
            }
        }
    }

    private var activeList: some View {
        let active = model.jobs.filter(\.isActive)
        return VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.vertical, 2)
            ForEach(active.prefix(3)) { j in
                HStack(spacing: 10) {
                    Thumb(url: j.thumbnail).frame(width: 40, height: 23)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(j.title).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(j.state == "running" && j.progress > 0 ? "\(Int(j.progress * 100))%" : j.stage)
                                .font(.ui(10.5).monospacedDigit()).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        ProgressBar(value: j.progress, indeterminate: j.state == "queued" || j.progress <= 0)
                    }
                    Button { model.cancel(j) } label: { Image(systemName: "xmark").font(.ui(9.5, .bold)) }
                        .buttonStyle(IconButtonStyle(size: 22)).help("Stop downloading")
                }
            }
            if active.count > 3 {
                Button("+\(active.count - 3) more") { model.showMainWindow() }
                    .buttonStyle(.plain).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            }
        }
        .transition(.opacity)
    }

    // MARK: logic

    private func prefill() {
        justStarted = false
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty && looksLikeLink(clip) && !model.jobs.contains(where: { $0.url == normalizeLink(clip) && $0.isActive }) {
            text = clip
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func lookup() async {
        
        info = nil
        lookupError = nil
        guard valid else { return }
        let target = normalizeLink(link)
        // YouTube: show the thumbnail at once and the title from oEmbed (~0.2 s),
        // while the full lookup (~3 s) fills in duration, chapters and the rest.
        let quick = FastPreview.quickInfo(link)
        if let quick {
            info = quick
            Task {
                if let o = await FastPreview.oembed(target), info?.url == target, info?.title == nil {
                    withAnimation(.easeOut(duration: 0.15)) { info?.title = o.title; info?.uploader = o.author }
                }
            }
        } else {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        looking = true
        defer { looking = false }
        do {
            let full = try await model.lookup(target)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { info = FastPreview.merge(quick: info, full: full) } }
        } catch {
            if !Task.isCancelled && quick == nil { lookupError = "Couldn't read that link. You can still try downloading it." }
        }
    }

    private func start() async {
        guard valid else { return }
        let url = normalizeLink(link)
        if model.tab == "transcript" {
            await model.transcript(url)
        } else if info?.isPlaylist == true {
            model.bulkPrefill = url
            model.showBulk = true
            model.showMainWindow()
            return
        } else if info?.isLive == true {
            lookupError = "This stream is live. Download it once it has ended."
            return
        } else if !(await model.download(url, info: info, kind: model.tab)) {
            return
        }
        text = ""
        info = nil
        justStarted = true
        try? await Task.sleep(for: .seconds(2))
        justStarted = false
    }
}

/// Behind-window blur for the floating panel.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
