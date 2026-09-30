// Character -> (virtual keycode, modifiers) for the CURRENT keyboard layout.
// Read-only: uses TIS + UCKeyTranslate, posts nothing.
import Carbon.HIToolbox
import Foundation
import CoreGraphics

public struct KeyStroke: Equatable, Sendable, CustomStringConvertible {
    public let keyCode: CGKeyCode
    public let shift: Bool
    public let option: Bool
    public var flags: CGEventFlags {
        var f: CGEventFlags = []
        if shift { f.insert(.maskShift) }
        if option { f.insert(.maskAlternate) }
        return f
    }
    public var description: String { "kc=\(keyCode)\(shift ? "+shift" : "")\(option ? "+opt" : "")" }
}

public struct LayoutKeyMap: Sendable {
    public let layoutID: String
    public let layoutName: String
    public let map: [Character: KeyStroke]
    public let deadKeys: [Character: KeyStroke]   // chars typed as <dead key> then Space (e.g. ' on US-International)

    /// Builds the table from the current ASCII-capable keyboard LAYOUT (not input method), so it works
    /// when the user has e.g. Japanese/Pinyin IME selected (those have no kTISPropertyUnicodeKeyLayoutData).
    public static func current() -> LayoutKeyMap? {
        // TISCopyCurrentKeyboardLayoutInputSource: the keyboard layout currently in use (even under an IME).
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return build(from: src) ?? {
            guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
            return build(from: ascii)
        }()
    }

    /// The key that produces `ch` while Command is held. Layouts such as "Dvorak - QWERTY ⌘" switch to a different
    /// arrangement under Command, so the plain table is the wrong place to look up a Cmd shortcut.
    public static func keyCodeWithCommand(for ch: Character) -> CGKeyCode? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return current()?.map[ch]?.keyCode }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        let kbdType = UInt32(LMGetKbdType())
        let mods = UInt32(cmdKey >> 8) & 0xFF
        let wanted = String(ch).lowercased()
        let found: CGKeyCode? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for kc in 0..<128 where !(65...92).contains(kc) {   // skip the numeric keypad block
                var deadState: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(layout, UInt16(kc), UInt16(kUCKeyActionDown), mods, kbdType,
                                     OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadState, chars.count, &len, &chars) == noErr,
                      len == 1, let u = Unicode.Scalar(chars[0]) else { continue }
                if String(Character(u)).lowercased() == wanted { return CGKeyCode(kc) }
            }
            return nil
        }
        return found ?? current()?.map[ch]?.keyCode
    }

    /// Build from any installed layout by input-source ID (used by tests; does not switch the system layout).
    public static func layout(id: String) -> LayoutKeyMap? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let src = list.first else { return nil }
        return build(from: src)
    }

    public static func build(from src: TISInputSource) -> LayoutKeyMap? {
        guard let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        let id = TISGetInputSourceProperty(src, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
        let name = TISGetInputSourceProperty(src, kTISPropertyLocalizedName).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
        let kbdType = UInt32(LMGetKbdType())

        var map: [Character: KeyStroke] = [:]
        var dead: [Character: KeyStroke] = [:]
        // Preference order: plain, shift, option, shift+option. First hit wins, lowest keycode wins within a level,
        // but prefer main-block keys over the numeric keypad (keycodes 65...92) so '1' maps to kVK_ANSI_1 not keypad 1.
        // Preference order: main-block keys at every modifier level first (plain, shift, option, shift+option),
        // THEN the numeric keypad (keycodes 65...92) as a last resort, so '*' is Shift+8 and '1' is kVK_ANSI_1.
        let combos: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        let passes: [[Int]] = [(0..<128).filter { !keypad.contains($0) }, (0..<128).filter { keypad.contains($0) }]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for order in passes {
              for combo in combos {
                // Carbon modifier bits >> 8 is what UCKeyTranslate wants.
                let mods = UInt32(((combo.shift ? shiftKey : 0) | (combo.option ? optionKey : 0)) >> 8) & 0xFF
                for kc in order {
                    var deadState: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let st = UCKeyTranslate(layout, UInt16(kc), UInt16(kUCKeyActionDown), mods, kbdType,
                                            0 /* keep dead keys as dead keys */, &deadState, chars.count, &len, &chars)
                    guard st == noErr else { continue }
                    if deadState != 0 {
                        // Dead key: pressing it prints nothing until the next key. Dead key + Space prints the accent itself.
                        var l2 = 0
                        var c2 = [UniChar](repeating: 0, count: 4)
                        if UCKeyTranslate(layout, UInt16(kVK_Space), UInt16(kUCKeyActionDown), 0, kbdType,
                                          0, &deadState, c2.count, &l2, &c2) == noErr, l2 == 1,
                           let u = Unicode.Scalar(c2[0]), dead[Character(u)] == nil {
                            dead[Character(u)] = KeyStroke(keyCode: CGKeyCode(kc), shift: combo.shift, option: combo.option)
                        }
                        continue
                    }
                    guard len == 1, let u = Unicode.Scalar(chars[0]) else { continue }
                    let ch = Character(u)
                    if u.value < 0x20 || u.value == 0x7F { continue }          // control chars handled explicitly below
                    if (0xF700...0xF8FF).contains(u.value) { continue }        // function-key private use
                    if map[ch] == nil { map[ch] = KeyStroke(keyCode: CGKeyCode(kc), shift: combo.shift, option: combo.option) }
                }
              }
            }
        }
        // Layout-independent keys.
        map["\n"] = KeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false, option: false)
        map["\t"] = KeyStroke(keyCode: CGKeyCode(kVK_Tab), shift: false, option: false)
        map[" "]  = KeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false, option: false)
        for k in map.keys { dead[k] = nil }   // a direct key always beats a dead-key sequence
        return LayoutKeyMap(layoutID: id, layoutName: name, map: map, deadKeys: dead)
    }
}

