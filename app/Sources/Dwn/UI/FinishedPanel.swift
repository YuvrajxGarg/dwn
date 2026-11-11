import AppKit
import SwiftUI

/// A finished download, as shown in the "Downloaded" panel.
struct FinishedItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var file: URL
    var thumbnail: String?
    var date = Date()
}

/// Where the panel appears. Top right sits under the menu bar, where
/// macOS shows its own notifications.
enum PanelCorner: String, CaseIterable, Identifiable {
    case topRight, bottomRight, topLeft, bottomLeft, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topRight: "Top right"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .bottomLeft: "Bottom left"
        case .off: "Don't show"
        }
    }
}

/// The small always-on-top "Downloaded" panel, like a download manager's:
/// it appears when downloads finish while Dwn is in the background, and
/// each file in it can be dragged straight into another app.
@MainActor
final class FinishedPanelController: ObservableObject {
    @Published var items: [FinishedItem] = []
    @Published var hovering = false {
        didSet { if hovering { hideTask?.cancel() } else { scheduleHide() } }
    }
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var corner: PanelCorner = .topRight

    func show(_ item: FinishedItem, corner: PanelCorner) {
        guard corner != .off else { return }
        self.corner = corner
        items.insert(item, at: 0)
        if items.count > 4 { items.removeLast(items.count - 4) }
        let p = panel ?? make()
        panel = p
        let wasVisible = p.isVisible
        DispatchQueue.main.async { [self] in
            p.layoutIfNeeded()
            place(p, offset: 0)
            if !wasVisible {
                p.alphaValue = 0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    p.animator().alphaValue = 1
                }
            }
        }
        scheduleHide()
    }

    func remove(_ item: FinishedItem) {
        items.removeAll { $0.id == item.id }
        if items.isEmpty { hide() } else if let p = panel { DispatchQueue.main.async { self.place(p, offset: 0) } }
    }

    func hide() {
        hideTask?.cancel()
        guard let p = panel, p.isVisible else { items = []; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in p.orderOut(nil); self.items = [] }
        })
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, !hovering else { return }
            hide()
        }
    }

    private func make() -> NSPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: FinishedPanelView(controller: self))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        p.contentViewController = host
        return p
    }

    private var screenFrame: NSRect {
        (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private func origin(_ size: NSSize, offset: CGFloat) -> NSPoint {
        let vf = screenFrame, m: CGFloat = 12
        let top = corner == .topRight || corner == .topLeft
        let right = corner == .topRight || corner == .bottomRight
        let x = right ? vf.maxX - size.width - m : vf.minX + m
        let y = top ? vf.maxY - size.height - m + offset : vf.minY + m - offset
        return NSPoint(x: x, y: y)
    }

    private func place(_ p: NSPanel, offset: CGFloat) {
        let size = p.contentViewController?.preferredContentSize ?? p.frame.size
        p.setFrame(NSRect(origin: origin(size, offset: offset), size: size), display: true)
    }
}

struct FinishedPanelView: View {
    @ObservedObject var controller: FinishedPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.ui(13, .semibold))
                Text(controller.items.count > 1 ? "\(controller.items.count) downloads finished" : "Download finished")
                    .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("Drag a file into any app").font(.ui(11)).foregroundStyle(Theme.text3)
                Button { controller.hide() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 22)).help("Close")
            }
            ForEach(controller.items) { FinishedRow(item: $0, controller: controller) }
        }
        .padding(12)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong))
        .onHover { controller.hovering = $0 }
        .preferredColorScheme(.dark)
    }
}

private struct FinishedRow: View {
    var item: FinishedItem
    @ObservedObject var controller: FinishedPanelController
    @Local private var hover = false

    private var size: String {
        let v = try? item.file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if v?.isDirectory == true { return "Folder" }
        return v?.fileSize.map { formatBytes(Double($0)) } ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.thumbnail != nil {
                    Thumb(url: item.thumbnail).frame(width: 64, height: 36)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.path)).resizable().frame(width: 32, height: 32)
                        .frame(width: 64, height: 36)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text([item.file.lastPathComponent, size].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.open(item.file) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(IconButtonStyle(size: 26)).help("Open")
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.file]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(IconButtonStyle(size: 26)).help("Show in Finder")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.raised : Theme.card))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: item.file) ?? NSItemProvider(object: item.file as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.file) }
        .help("Drag into another app, or double-click to open")
    }
}
