import AppKit
import Combine

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
        item?.menu = m
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func quick() { model.quickPanel.show() }
    @objc private func quitApp() { quitDwn() }
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

    /// The drop arrow on a baseline, drawn as a template image so it follows the menu bar's colour.
    static func icon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let w: CGFloat = 8.5, h: CGFloat = 11.5
            let x = (r.width - w) / 2, y: CGFloat = 1.5
            let stemHalf = w * 0.17
            let headTop = y + h * 0.46
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x + w / 2 - stemHalf, y: headTop))
            p.line(to: NSPoint(x: x + w / 2 - stemHalf, y: y + stemHalf))
            p.appendArc(withCenter: NSPoint(x: x + w / 2, y: y + stemHalf), radius: stemHalf,
                        startAngle: 180, endAngle: 0, clockwise: false)
            p.line(to: NSPoint(x: x + w / 2 + stemHalf, y: headTop))
            p.line(to: NSPoint(x: x + w, y: headTop))
            p.line(to: NSPoint(x: x + w / 2, y: y + h))
            p.line(to: NSPoint(x: x, y: headTop))
            p.close()
            NSColor.black.setFill()
            p.fill()
            let base = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 15, width: 11, height: 1.8), xRadius: 0.9, yRadius: 0.9)
            base.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
