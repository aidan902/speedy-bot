import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut the tech chose for "type the clipboard into the session".
struct HotKeySpec: Equatable {
    var keyCode: Int
    var carbonModifiers: Int

    static let defaultLabel = "⇧⌘V"   // modifier order as macOS menus print it

    /// The stored shortcuts: typing into a session, pasting a screenshot into ChatGPT, capturing the session window.
    enum Slot: String { case typing, paste, capture }

    static func load(_ slot: Slot) -> HotKeySpec? {
        let d = SpeedyShared.defaults
        guard let code = d.object(forKey: slot.rawValue + "KeyCode") as? Int,
              let mods = d.object(forKey: slot.rawValue + "Modifiers") as? Int else { return nil }
        return HotKeySpec(keyCode: code, carbonModifiers: mods)
    }

    static func save(_ spec: HotKeySpec?, _ slot: Slot) {
        let d = SpeedyShared.defaults
        if let spec {
            d.set(spec.keyCode, forKey: slot.rawValue + "KeyCode")
            d.set(spec.carbonModifiers, forKey: slot.rawValue + "Modifiers")
        } else {
            d.removeObject(forKey: slot.rawValue + "KeyCode")
            d.removeObject(forKey: slot.rawValue + "Modifiers")
        }
    }

    init(keyCode: Int, carbonModifiers: Int) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }

    init(keyCode: Int, flags: NSEvent.ModifierFlags) {
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        self.init(keyCode: keyCode, carbonModifiers: mods)
    }

    /// ScreenConnect forwards every modifier press at once (Cmd as the Windows key, Option as Alt) but never sees
    /// the key the shortcut swallows. ⌘T therefore reaches the remote as a bare Windows-key tap (the Start menu
    /// opens) and ⌥T as a bare Alt tap (the menu bar activates), and the typed text goes there. A Shift or
    /// Control in the combination cancels both.
    var leavesBareModifierTapOnRemote: Bool {
        carbonModifiers & (cmdKey | optionKey) != 0 && carbonModifiers & (shiftKey | controlKey) == 0
    }

    /// "⌃⌥⇧⌘T", in the order macOS menus use.
    var label: String {
        var s = ""
        if carbonModifiers & controlKey != 0 { s += "⌃" }
        if carbonModifiers & optionKey != 0 { s += "⌥" }
        if carbonModifiers & shiftKey != 0 { s += "⇧" }
        if carbonModifiers & cmdKey != 0 { s += "⌘" }
        return s + KeyNames.name(keyCode: keyCode)
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func isFunctionKey(_ keyCode: Int) -> Bool { special[keyCode]?.hasPrefix("F") == true }

    /// What is printed on the key in the current keyboard layout.
    static func name(keyCode: Int) -> String {
        if let s = special[keyCode] { return s }
        if let map = LayoutKeyMap.current()?.map,
           let ch = map.first(where: { Int($0.value.keyCode) == keyCode && !$0.value.shift && !$0.value.option })?.key {
            return String(ch).uppercased()
        }
        return "key \(keyCode)"
    }
}

/// A button that shows a shortcut and, when clicked, takes the next key combination pressed.
struct ShortcutRecorder: View {
    /// What the button shows when it is not recording.
    let label: String
    /// Shown only when there is something to go back to (a default).
    let resetLabel: String?
    let onChange: (HotKeySpec?) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press the keys…" : label) { recording ? stop() : start() }
                .frame(minWidth: 92)
                .help("Click, then press the shortcut you want. Esc cancels.")
            if let resetLabel, !recording {
                Button("Reset") { onChange(nil) }
                    .controlSize(.small)
                    .help("Back to \(resetLabel)")
            }
        }
        .onDisappear { stop() }
        // Closing the window or switching to another app must end the recording, or the next keys typed into
        // Speedy Bot would be swallowed and the first one with a modifier kept as the shortcut.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        recording = true
        // A local monitor sees the key before the app's own menus do, so combinations such as ⌘T or ⌘W can be
        // chosen. A mouse button that a mouse utility maps to a keystroke arrives here as that keystroke.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let code = Int(event.keyCode)
            if code == kVK_Escape && flags.isEmpty { stop(); return nil }
            // A bare letter or Shift+letter would hijack ordinary typing.
            let strongModifier = !flags.intersection([.command, .option, .control]).isEmpty
            guard strongModifier || KeyNames.isFunctionKey(code) else { NSSound.beep(); return nil }
            onChange(HotKeySpec(keyCode: code, flags: flags))
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
