import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    /// One Dwn at a time: two copies would share (and overwrite) the same
    /// downloads, history and settings. A second launch brings the first forward.
    func applicationWillFinishLaunching(_ notification: Notification) {
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
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UNUserNotificationCenter.current().delegate = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { self.model?.handle(url: $0) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.engine.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit requests from outside the app (AppleScript, logout, the updater's
    /// helper) arrive as an Apple event; route them through quitDwn() so an
    /// open sheet can't cancel them.
    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { quitDwn() }
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
                    for w in NSApp.windows {
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

/// AppKit cancels quitting while any window has a sheet attached, and SwiftUI
/// keeps its sheets attached until its own state says they're closed. So close
/// every sheet through the model, give them a moment to animate away, then quit.
@MainActor
func quitDwn() {
    if let m = AppModel.current {
        m.showBulk = false
        m.showSignIn = false
        m.sectionTarget = nil
        m.updater.showSheet = false
    }
    func attempt(_ tries: Int) {
        let open = NSApp.windows.contains { $0.attachedSheet != nil }
        if open && tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(tries - 1) }
        } else {
            NSApp.terminate(nil)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(15) }
}
