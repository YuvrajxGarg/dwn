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

    /// The "dwn↓" wordmark as a template image, so macOS tints it for light and dark menu bars.
    static func icon() -> NSImage {
        let size: CGFloat = 13.5
        let font = NSFont.systemFont(ofSize: size, weight: .black)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "dwn", attributes: [
            .font: font, .kern: -size * 0.055, .foregroundColor: NSColor.black]))
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - size * 0.055
        let gap = size * 0.07, aw = size * 0.36, ah = size * 0.56
        let height: CGFloat = 18
        let width = ceil(textW + gap + aw) + 1
        let baseline = floor((height - font.xHeight) / 2)
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.textPosition = CGPoint(x: 0.5, y: baseline)
            CTLineDraw(line, cg)
            // Drop arrow sitting on the baseline (y-up).
            let r = CGRect(x: 0.5 + textW + gap, y: baseline, width: aw, height: ah)
            let half = aw * 0.17, headTop = r.minY + ah * 0.54
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.midX - half, y: headTop))
            p.addLine(to: CGPoint(x: r.midX - half, y: r.maxY - half))
            p.addArc(center: CGPoint(x: r.midX, y: r.maxY - half), radius: half, startAngle: .pi, endAngle: 0, clockwise: true)
            p.addLine(to: CGPoint(x: r.midX + half, y: headTop))
            p.addLine(to: CGPoint(x: r.maxX, y: headTop))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: headTop))
            p.closeSubpath()
            cg.addPath(p)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Dwn"
        return img
    }
}
