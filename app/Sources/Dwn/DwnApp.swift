import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { self.model?.handle(url: $0) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.engine.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
