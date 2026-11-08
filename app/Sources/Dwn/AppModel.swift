import AppKit
import ServiceManagement
import Foundation
import UserNotifications

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

@MainActor
final class AppModel: ObservableObject {
    let engine = Engine()
    @Published var health: Health?
    @Published var prefs = Prefs()
    @Published var jobs: [Job] = []
    @Published var history: [HistoryItem] = []
    @Published var historyLoaded = false
    @Published var toasts: [Toast] = []
    @Published var showBulk = false
    @Published var bulkPrefill = ""
    @Published var sectionTarget: LinkInfo?
    @Published var composerText = ""
    @Published var onboarded = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    /// Composer tab: video, audio or transcript (transcript is app-only, not an engine pref).
    @Published var tab = UserDefaults.standard.string(forKey: "tab") ?? "video" {
        didSet {
            UserDefaults.standard.set(tab, forKey: "tab")
            if tab != "transcript" && prefs.kind != tab { updatePrefs { $0.kind = tab } }
        }
    }
    @Published var showSignIn = false
    @Published var sectionChoice: SectionChoice?
    @Published var freeBytes: Int64?
    @Published var hotkeyEnabled = UserDefaults.standard.object(forKey: "hotkey") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkey"); applyHotKey() }
    }
    @Published private(set) var shortcut = Shortcut.load()
    @Published private(set) var hotKeyFailed = false
    /// What the shortcut does: "panel" opens the quick panel, "instant" downloads the copied link.
    @Published var shortcutAction = UserDefaults.standard.string(forKey: "shortcutAction") ?? "panel" {
        didSet { UserDefaults.standard.set(shortcutAction, forKey: "shortcutAction") }
    }
    /// Where the quick panel appears: "top" (under the menu bar) or "bottom" right.
    @Published var panelPosition = UserDefaults.standard.string(forKey: "panelPosition") ?? "top" {
        didSet { UserDefaults.standard.set(panelPosition, forKey: "panelPosition") }
    }
    @Published var menuBarEnabled = UserDefaults.standard.object(forKey: "menuBar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(menuBarEnabled, forKey: "menuBar")
            if !menuBarEnabled { hideDock = false }
            statusItem.setVisible(menuBarEnabled)
        }
    }
    @Published var hideDock = UserDefaults.standard.bool(forKey: "hideDock") {
        didSet { UserDefaults.standard.set(hideDock, forKey: "hideDock"); applyDockPolicy() }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Opens the main window; set by the SwiftUI scene once it exists.
    var openMainWindow: (() -> Void)?
    lazy var quickPanel = QuickPanelController(model: self)
    lazy var statusItem = StatusItemController(model: self)
    let updater = Updater()

    private var signInPromptShown = false
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var prefsTask: Task<Void, Never>?
    private var prefsLoaded = false
    private var knownDone = Set<String>()
    private let hotKey = HotKey()

    var api: API? { engine.api }
    var activeJobs: [Job] { jobs.filter { $0.isActive || $0.state == "failed" || $0.state == "cancelled" } }

    init() {
        engine.onReady = { [weak self] in self?.engineReady() }
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
    }

    func start() {
        guard !started else { return }
        started = true
        engine.start()
        applyHotKey()
        statusItem.setVisible(menuBarEnabled)
        applyDockPolicy()
        updater.start()
    }

    private func engineReady() {
        Task {
            guard let api else { return }
            health = try? await api.call("health")
            if let p: Prefs = try? await api.call("prefs") { prefs = p }
            refreshFreeSpace()
            prefsLoaded = true
            await refreshHistory()
            await refreshJobs()
            startPolling()
        }
    }

    // MARK: polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refreshJobs()
                let busy = jobs.contains { $0.isActive }
                try? await Task.sleep(for: .milliseconds(busy ? 500 : 2000))
            }
        }
    }

    func refreshJobs() async {
        guard let api, let list: [Job] = try? await api.call("jobs") else { return }
        if list != jobs { jobs = list }
        var newlyDone = false
        for j in list where j.state == "done" && !knownDone.contains(j.id) {
            knownDone.insert(j.id)
            newlyDone = true
            notifyFinished(j)
            // Finished jobs move into the history list.
            _ = try? await api.call("jobs/\(j.id)/dismiss", [:], as: [String: Bool].self)
        }
        if newlyDone { await refreshHistory(); refreshFreeSpace() }
        if list.contains(where: { $0.errorCode == "signin" && $0.state == "failed" }) && !signInPromptShown {
            signInPromptShown = true
            showSignIn = true
        }
        let active = list.filter(\.isActive).count
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }

    func refreshHistory() async {
        guard let api, let items: [HistoryItem] = try? await api.call("history") else { return }
        history = items
        historyLoaded = true
    }

    private func notifyFinished(_ j: Job) {
        guard !NSApp.isActive else { return }
        let c = UNMutableNotificationContent()
        c.title = "Downloaded"
        c.body = j.title
        c.userInfo = ["file": j.file ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: j.id, content: c, trigger: nil))
    }

    // MARK: prefs

    func updatePrefs(_ change: (inout Prefs) -> Void) {
        change(&prefs)
        guard prefsLoaded else { return }
        prefsTask?.cancel()
        let snapshot = prefs
        prefsTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let api else { return }
            do { _ = try await api.savePrefs(snapshot) } catch { toast("Couldn't save your settings. \(error.localizedDescription)", error: true) }
        }
    }

    // MARK: actions

    func toast(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toasts.append(t)
        Task {
            try? await Task.sleep(for: .seconds(error ? 6 : 3))
            toasts.removeAll { $0.id == t.id }
        }
    }

    func lookup(_ url: String) async throws -> LinkInfo {
        guard let api else { throw APIError(message: "Engine not running") }
        return try await api.call("info", ["url": url])
    }

    @discardableResult
    func download(_ url: String, info: LinkInfo? = nil, kind: String? = nil, format: String? = nil,
                  start: Double? = nil, end: Double? = nil, mode: String = "normal") async -> Bool {
        guard let api else { toast("The download engine isn't running yet.", error: true); return false }
        let k = kind ?? prefs.kind
        var body: [String: Any] = [
            "url": url, "kind": k, "mode": mode,
            "format": format ?? (k == "video" ? prefs.videoFormat : prefs.audioFormat),
        ]
        if let t = info?.title { body["title"] = t }
        if let t = info?.thumbnail { body["thumbnail"] = t }
        if let start { body["start"] = start }
        if let end { body["end"] = end }
        do {
            let _: Job = try await api.call("download", body)
            await refreshJobs()
            return true
        } catch {
            toast(error.localizedDescription, error: true)
            return false
        }
    }

    func transcript(_ url: String) async {
        guard let api else { return }
        toast("Looking for captions")
        do {
            let r: FileResult = try await api.call("transcript", ["url": url])
            await refreshHistory()
            toast("Transcript saved: \((r.file as NSString).lastPathComponent)")
        } catch { toast(error.localizedDescription, error: true) }
    }

    func cancel(_ j: Job) { jobAction(j, "cancel") }
    func retry(_ j: Job) { jobAction(j, "retry") }
    func dismiss(_ j: Job) { jobAction(j, "dismiss") }

    private func jobAction(_ j: Job, _ action: String) {
        Task {
            guard let api else { return }
            _ = try? await api.call("jobs/\(j.id)/\(action)", [:], as: AnyDecodable.self)
            await refreshJobs()
        }
    }

    func cancelAll() {
        Task {
            _ = try? await api?.call("jobs/cancel-all", [:], as: AnyDecodable.self)
            await refreshJobs()
        }
    }

    func forget(_ ids: [String]) {
        Task {
            _ = try? await api?.call("history/forget", ["ids": ids], as: AnyDecodable.self)
            await refreshHistory()
        }
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else { toast("That file isn't there anymore.", error: true) }
    }

    func open(_ path: String?) {
        guard let path else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else { toast("That file isn't there anymore.", error: true) }
    }

    func openFolder() {
        let url = URL(fileURLWithPath: prefs.folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func trash(_ item: HistoryItem) {
        guard let f = item.file else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil)
            forget([item.id])
        } catch { toast("Couldn't move that to the Trash.", error: true) }
    }

    /// Global shortcut / menu command: download whatever link is on the clipboard.
    func downloadClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter(looksLikeLink)
        if lines.count > 1 {
            bulkPrefill = lines.joined(separator: "\n")
            showBulk = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let first = lines.first ?? (looksLikeLink(text) ? text : nil) else {
            toast("There's no link on the clipboard.", error: true)
            return
        }
        Task {
            if await download(normalizeLink(first)) { toast("Download started.") }
        }
    }

    /// dwn://download?url=…  (used by the bookmarklet)
    func handle(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        let mode = comps.queryItems?.first(where: { $0.name == "kind" })?.value
        Task {
            if await download(target, kind: mode) { toast("Download started.") }
        }
    }

    func updateEngine() async -> String {
        guard let api else { return "Engine not running" }
        do {
            let r: UpdateResult = try await api.call("update-ytdlp", [:])
            if r.updated {
                engine.restart()
                return "Updated yt-dlp to \(r.version). The engine restarted."
            }
            return "Up to date. You have the newest yt-dlp (\(r.version))."
        } catch { return error.localizedDescription }
    }

    func refreshFreeSpace() {
        var url = URL(fileURLWithPath: prefs.folder)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = v?.volumeAvailableCapacityForImportantUsage
    }

    var installedBrowsers: [Browser] {
        Browser.all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Reads the browser's cookies through the engine. macOS asks for the Keychain
    /// password the first time; "Always Allow" keeps it from asking again.
    func checkLogin(_ browser: String) async -> LoginCheck {
        guard let api else { return LoginCheck(ok: false, message: "The download engine isn't running.") }
        do { return try await api.call("cookies/test", ["browser": browser]) }
        catch { return LoginCheck(ok: false, message: error.localizedDescription) }
    }

    func openYouTube(in browser: Browser) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let yt = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/") else { return }
        NSWorkspace.shared.open([yt], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func retrySignInFailures() {
        for j in jobs where j.errorCode == "signin" && j.state == "failed" { retry(j) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.folder)
        panel.prompt = "Choose"
        panel.message = "Choose where Dwn saves downloads"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.isWritableFile(atPath: url.path) {
            updatePrefs { $0.folder = url.path }
            refreshFreeSpace()
        } else {
            toast("That folder can't be written to. Pick another.", error: true)
        }
    }

    func applyHotKey() {
        if hotkeyEnabled { hotKey.register(shortcut); hotKeyFailed = hotKey.failed } else { hotKey.unregister() }
    }

    func suspendHotKey() { hotKey.unregister() }

    func setShortcut(_ s: Shortcut) {
        shortcut = s
        s.save()
        applyHotKey()
    }

    func shortcutPressed() {
        if shortcutAction == "instant" { downloadClipboard() } else { quickPanel.toggle() }
    }

    func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = (hideDock && menuBarEnabled) ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            toast("Couldn't change that: \(error.localizedDescription)", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            toast("Allow Dwn in System Settings > General > Login Items.", error: true)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func showMainWindow() {
        quickPanel.hide()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { ($0.identifier?.rawValue.hasPrefix("main") ?? false) && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// Accepts any JSON reply when only success matters.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
