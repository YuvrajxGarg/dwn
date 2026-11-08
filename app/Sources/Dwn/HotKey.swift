import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination the user picked, stored in UserDefaults.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var key: String            // the key's label, e.g. "D" or "Space"

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey | cmdKey), key: "D")

    /// "⌃⌥⇧⌘" order, as macOS menus show it.
    var symbols: [String] {
        var s: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { s.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { s.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { s.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { s.append("⌘") }
        return s + [key]
    }

    var display: String { symbols.joined() }

    static func from(_ event: NSEvent) -> Shortcut? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        // Needs Command, Option or Control so it doesn't swallow normal typing.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: m, key: label(for: event))
    }

    private static func label(for e: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(e.keyCode)] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static func load() -> Shortcut {
        guard let d = UserDefaults.standard.data(forKey: "shortcut"),
              let s = try? JSONDecoder().decode(Shortcut.self, from: d) else { return .default }
        return s
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "shortcut")
    }
}

/// A system-wide shortcut using the Carbon hot key API, which needs no
/// Accessibility permission.
final class HotKey {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastPress = Date.distantPast
    private(set) var failed = false

    func register(_ s: Shortcut) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
            if Date().timeIntervalSince(hk.lastPress) > 0.3 {
                hk.lastPress = Date()
                DispatchQueue.main.async { hk.onPress?() }
            }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x44574E31), id: 1) // "DWN1"
        let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        failed = status != noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

/// Click, then press the new key combination. Esc cancels, Delete resets.
struct ShortcutRecorder: View {
    @EnvironmentObject var model: AppModel
    @Local private var recording = false
    @Local private var monitor: Any?
    @Local private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 4) {
                    if recording {
                        Text("Press keys…").font(.ui(12.5, .medium)).foregroundStyle(Theme.accent)
                    } else {
                        ForEach(model.shortcut.symbols, id: \.self) { k in
                            Text(k).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                                .frame(minWidth: 22, minHeight: 22)
                                .padding(.horizontal, k.count > 1 ? 5 : 0)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.strokeStrong))
                        }
                    }
                }
                .padding(.horizontal, 8).frame(minWidth: 110, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(recording ? Theme.accent : Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("Click, then press a new shortcut")
            if let hint { Text(hint).font(.ui(11.5)).foregroundStyle(Theme.warn) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = nil
        model.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if e.keyCode == UInt16(kVK_Delete) { model.setShortcut(.default); stop(); return nil }
            if let s = Shortcut.from(e) {
                model.setShortcut(s)
                stop()
                if model.hotKeyFailed { hint = "Another app is already using \(s.display)." }
            } else {
                hint = "Include ⌘, ⌥ or ⌃"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; model.applyHotKey() }
    }
}
