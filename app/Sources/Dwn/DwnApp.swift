import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    /// One Dwn at a time: two copies would share (and overwrite) the same
    /// downloads, history and settings. A second launch brings the first forward.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by "Open at login"? Then start in the background (menu bar only).
        if let e = NSAppleEventManager.shared().currentAppleEvent,
           e.eventID == AEEventID(kAEOpenApplication),
           e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
        guard ProcessInfo.processInfo.environment["DWN_ALLOW_SECOND_INSTANCE"] == nil,
              let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            other.activate()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Dark mode for Dwn's own windows only. Setting it app-wide (NSApp.appearance)
        // also reached the menu bar icon, which then drew on a solid dark plate
        // instead of the menu bar's see-through background.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let w = n.object as? NSWindow, w.appearance?.name != .darkAqua,
                      !w.className.contains("StatusBar"), !w.className.contains("NSMenu") else { return }
                w.appearance = NSAppearance(named: .darkAqua)
            }
        }
        UNUserNotificationCenter.current().delegate = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { self.model?.handle(url: $0) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.updater.installOnQuit()   // a downloaded update goes in as Dwn quits
            model?.engine.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit requests from outside the app (AppleScript, logout, the updater's
    /// helper) arrive as an Apple event; route them through quitDwn() so an
    /// open sheet can't cancel them.
    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        // Logging out, restarting and shutting down say why; those always quit.
        // A plain Quit (from the Dock, say) keeps Dwn running in the menu bar.
        let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        MainActor.assumeIsolated { quitDwn(force: reason != nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model?.showMainWindow() } }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let f = info["file"] as? String, !f.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
        }
        if info["update"] != nil {
            Task { @MainActor in
                self.model?.showMainWindow()
                self.model?.updater.showSheet = true
            }
        }
        done()
    }
}

@main
struct DwnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Dwn", id: "main") {
            RootView(engine: model.engine)
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    model.start()
                    if launchedAtLogin && model.menuBarEnabled {
                        launchedAtLogin = false
                        DispatchQueue.main.async { moveToBackground(announce: false) }
                    }
                    // Only Dwn's main window. The menu bar icon lives in a window of its
                    // own; painting that one is what drew the dark box behind the icon.
                    for w in NSApp.windows where (w.identifier?.rawValue.hasPrefix("main") ?? false) {
                        w.isMovableByWindowBackground = true
                        w.backgroundColor = NSColor(Theme.bg)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Dwn") { quitDwn() }.keyboardShortcut("q")
                Button("Quit Dwn Completely") { quitDwn(force: true) }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check(manual: true); if model.updater.hasUpdate { model.updater.showSheet = true } }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Download Copied Link") { model.downloadClipboard() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Bulk Download…") { model.showBulk = true }
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                Button("Open Download Folder") { model.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Set when macOS opened Dwn as a login item.
@MainActor var launchedAtLogin = false

/// Close every sheet through the model (AppKit cancels quitting while a sheet is
/// attached, and SwiftUI keeps its sheets attached until its state says closed).
@MainActor
private func closeSheets(then done: @escaping () -> Void) {
    if let m = AppModel.current {
        m.showBulk = false
        m.showSignIn = false
        m.sectionTarget = nil
        m.updater.showSheet = false
    }
    func attempt(_ tries: Int) {
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) && tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(tries - 1) }
        } else {
            done()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(15) }
}

/// Quit, or with the menu bar icon on, keep running in the background.
/// `force` (the menu bar's Quit, updates, logout) always quits.
@MainActor
func quitDwn(force: Bool = false) {
    if !force, AppModel.current?.menuBarEnabled == true {
        moveToBackground(announce: true)
        return
    }
    closeSheets { NSApp.terminate(nil) }
}

/// Close the windows and the Dock icon; downloads keep going and the menu bar
/// icon stays. Clicking it (or opening Dwn again) brings the window back.
@MainActor
func moveToBackground(announce: Bool) {
    closeSheets {
        AppModel.current?.quickPanel.hide()
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) && w.className != "NSStatusBarWindow" {
            w.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
        let key = "backgroundExplained"
        if announce && !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let c = UNMutableNotificationContent()
            c.title = "Dwn is still running"
            c.body = "It stays in the menu bar so downloads keep going. Choose Quit Dwn there to quit completely."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "background", content: c, trigger: nil))
        }
    }
}
