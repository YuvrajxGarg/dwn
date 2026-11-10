import AppKit
import Combine
import CoreText

/// The menu bar icon. Click opens the quick panel; right-click (or Control-click) shows a menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let model: AppModel
    private var item: NSStatusItem?
    private var sub: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    func setVisible(_ on: Bool) {
        if on, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.image = Self.icon()
            it.button?.imagePosition = .imageLeading
            // No grey box behind the icon, even while it's pressed.
            (it.button?.cell as? NSButtonCell)?.highlightsBy = []
            it.button?.focusRingType = .none
            it.button?.target = self
            it.button?.action = #selector(clicked(_:))
            it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            it.button?.toolTip = "Dwn"
            item = it
            sub = model.$jobs.receive(on: RunLoop.main).sink { [weak self] jobs in
                let n = jobs.filter(\.isActive).count
                self?.item?.button?.title = n > 0 ? " \(n)" : ""
            }
        } else if !on, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            sub = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            model.quickPanel.toggle()
        }
        // Never leave the button drawn in its pressed state (the grey box behind the icon).
        sender.highlight(false)
    }

    private func showMenu() {
        let m = NSMenu()
        let quick = NSMenuItem(title: "Quick Download", action: #selector(quick), keyEquivalent: "")
        quick.target = self
        m.addItem(quick)
        let copied = NSMenuItem(title: "Download Copied Link", action: #selector(copied), keyEquivalent: "")
        copied.target = self
        m.addItem(copied)
        let bulk = NSMenuItem(title: "Bulk Download…", action: #selector(bulk), keyEquivalent: "")
        bulk.target = self
        m.addItem(bulk)
        m.addItem(.separator())
        let active = model.jobs.filter(\.isActive).count
        if active > 0 {
            let info = NSMenuItem(title: "\(active) downloading", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
        }
        let open = NSMenuItem(title: "Open Dwn", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        m.addItem(open)
        let folder = NSMenuItem(title: "Open Download Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        m.addItem(folder)
        if model.updater.hasUpdate, let v = model.updater.latest?.version {
            let up = NSMenuItem(title: "Update to \(v)…", action: #selector(showUpdate), keyEquivalent: "")
            up.target = self
            m.addItem(up)
        } else {
            let up = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
            up.target = self
            m.addItem(up)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        m.addItem(settings)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dwn", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        // Pop the menu up under the icon directly. (Assigning item.menu and simulating a
        // click left the button stuck in its highlighted state.)
        if let button = item?.button {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            button.highlight(false)
        }
    }

    @objc private func quick() { model.quickPanel.show() }
    @objc private func quitApp() { quitDwn(force: true) }
    @objc private func showUpdate() { model.showMainWindow(); model.updater.showSheet = true }
    @objc private func checkUpdates() {
        Task {
            await model.updater.check(manual: true)
            model.showMainWindow()
            if model.updater.hasUpdate { model.updater.showSheet = true }
            else { model.toast(model.updater.phase == .upToDate ? "Dwn is up to date." : "Couldn't check for updates.") }
        }
    }
    @objc private func copied() { model.downloadClipboard() }
    @objc private func bulk() { model.showMainWindow(); model.showBulk = true }
    @objc private func openMain() { model.showMainWindow() }
    @objc private func openFolder() { model.openFolder() }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// A download symbol: an arrow dropping into an open tray, in even rounded
    /// strokes. Template image, so macOS tints it for light and dark menu bars.
    static func icon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            DownloadGlyph.draw(in: cg, size: 18, color: NSColor.black.cgColor, flipped: true)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Dwn"
        return img
    }
}

/// The download symbol, shared by the menu bar icon (and mirrored in tools/make_icon.swift for Windows).
enum DownloadGlyph {
    /// Draws on an 18-unit grid scaled to `size`. `flipped` = y grows downwards.
    static func draw(in cg: CGContext, size: CGFloat, color: CGColor, flipped: Bool) {
        let k = size / 18
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: (flipped ? y : 18 - y) * k) }
        cg.setStrokeColor(color)
        cg.setLineWidth(1.75 * k)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        // Arrow: stem and head.
        cg.move(to: pt(9, 2.6)); cg.addLine(to: pt(9, 11.2))
        cg.move(to: pt(5.4, 7.8)); cg.addLine(to: pt(9, 11.4)); cg.addLine(to: pt(12.6, 7.8))
        // Open tray it lands in.
        cg.move(to: pt(3, 11.6)); cg.addLine(to: pt(3, 13.6))
        cg.addQuadCurve(to: pt(4.8, 15.4), control: pt(3, 15.4))
        cg.addLine(to: pt(13.2, 15.4))
        cg.addQuadCurve(to: pt(15, 13.6), control: pt(15, 15.4))
        cg.addLine(to: pt(15, 11.6))
        cg.strokePath()
    }
}
