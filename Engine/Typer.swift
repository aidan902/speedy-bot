// Turn text into keycode+modifier key events for the frontmost app (a ScreenConnect session).
// Building the plan is pure; posting it needs the Accessibility permission.
import CoreGraphics
import Carbon.HIToolbox
import Foundation

public struct PlannedKey: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable { case key, shiftDown, shiftUp }
    public let kind: Kind
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags          // EXACT flags to stamp on both down and up
    public let unicodeFallback: String?     // non-nil => keycode 0 + keyboardSetUnicodeString (char not on the layout)
    public var description: String {
        switch kind {
        case .shiftDown: return "[shift down]"
        case .shiftUp: return "[shift up]"
        case .key: return unicodeFallback.map { "U(\($0))" } ?? "k\(keyCode)\(flags.contains(.maskShift) ? "S" : "")\(flags.contains(.maskAlternate) ? "O" : "")"
        }
    }
}

public struct TypingOptions: Sendable {
    /// Bracket shifted characters with real Shift key-down/up (keycode 56) like hardware does. Most faithful for a client that
    /// forwards key-by-key; consecutive shifted characters share one Shift press.
    public var explicitShiftKeyEvents = true
    /// Allow characters that need Option on the local layout. OFF for remote typing: Option becomes Alt on a Windows guest and prints something else.
    public var allowOptionLayer = false
    /// Characters that are not reachable: send keycode 0 + unicode string (works in local Cocoa apps; a keycode-forwarding client will likely print "a").
    public var unicodeFallback = false
    /// Replace typographic characters by their ASCII cousins before mapping.
    public var asciiFold = true
    /// Default pace is ~33 characters a second. No ScreenConnect-specific figure exists; this is the conservative
    /// remote-desktop auto-type pace. `fast` is ~50/s for sessions that keep up.
    public var keyHoldMicros: UInt32 = 10_000
    public var interKeyMicros: UInt32 = 20_000
    public static var fast: TypingOptions { var o = TypingOptions(); o.keyHoldMicros = 8_000; o.interKeyMicros = 12_000; return o }
    public init() {}
}

public struct TypingPlan: Sendable {
    public let keys: [PlannedKey]
    public let skipped: [Character]
}

public enum TextTyper {
    static let fold: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2013}": "-", "\u{2014}": "-",
        "\u{2026}": "...", "\u{00A0}": " ", "\u{2022}": "*", "\u{2192}": "->",
    ]

    /// Pure function: no events are created or posted.
    public static func plan(_ text: String, keyMap: LayoutKeyMap, options: TypingOptions = TypingOptions()) -> TypingPlan {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if options.asciiFold { s = String(s.flatMap { c in Array(fold[c] ?? String(c)) }) }
        var keys: [PlannedKey] = []
        var skipped: [Character] = []
        var shiftHeld = false
        func setShift(_ want: Bool) {
            guard options.explicitShiftKeyEvents, want != shiftHeld else { return }
            shiftHeld = want
            keys.append(PlannedKey(kind: want ? .shiftDown : .shiftUp, keyCode: CGKeyCode(kVK_Shift),
                                   flags: want ? .maskShift : [], unicodeFallback: nil))
        }
        func emit(_ ks: KeyStroke) {
            setShift(ks.shift)
            keys.append(PlannedKey(kind: .key, keyCode: ks.keyCode, flags: ks.flags, unicodeFallback: nil))
        }
        for ch in s {
            if let ks = keyMap.map[ch], options.allowOptionLayer || !ks.option {
                emit(ks)
            } else if let dk = keyMap.deadKeys[ch], options.allowOptionLayer || !dk.option {
                emit(dk)                                                                   // dead key ...
                emit(KeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false, option: false)) // ... then Space prints the accent itself
            } else if options.unicodeFallback {
                setShift(false)
                keys.append(PlannedKey(kind: .key, keyCode: 0, flags: [], unicodeFallback: String(ch)))
            } else {
                skipped.append(ch)
            }
        }
        setShift(false)
        return TypingPlan(keys: keys, skipped: skipped)
    }

    // MARK: physical modifier state (read-only, no permission needed)

    static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    /// True while the user is PHYSICALLY holding Cmd/Shift/Option/Control (hardware state, ignores synthetic events).
    public static func physicalModifiersDown() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty
    }

    /// Cmd / Control / Option physically held. Shift is left out on purpose: the typer presses Shift itself.
    public static func physicalCommandKeysDown() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }

    public static var capsLockOn: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    /// How the wait for the shortcut's keys went. Timings and yes/no only, for the log.
    public struct ReleaseWait: Sendable {
        public let released: Bool
        public let waitedMs: Int
        public let sawHardware: Bool       // the keyboard itself showed the shortcut's keys down
        public let sawSoftwareOnly: Bool   // only software did (a mouse utility or macro tool pressed them)
    }

    /// Blocks (call OFF the main thread) until the shortcut's own keys are up and have STAYED up for a moment.
    /// Required for remote typing: the remote client has already seen Cmd/Shift go down, and it puts the Windows
    /// key on every key it forwards until it has seen them come back up. Typing too early turns the first letters
    /// into Win+letter shortcuts on the other end (the first character simply disappears).
    /// Both the hardware state and the session state are checked: a mouse button mapped to a keystroke presses
    /// the keys in software, which the hardware state never shows.
    public static func waitForPhysicalRelease(key: CGKeyCode = CGKeyCode(kVK_ANSI_V), timeout: TimeInterval = 3.0) -> ReleaseWait {
        func held(_ s: CGEventSourceStateID) -> Bool {
            !CGEventSource.flagsState(s).intersection(modifierMask).isEmpty || CGEventSource.keyState(s, key: key)
        }
        let start = Date(), deadline = start.addingTimeInterval(timeout)
        var quietSince: Date?, sawHardware = false, sawSoftwareOnly = false
        func result(_ ok: Bool) -> ReleaseWait {
            ReleaseWait(released: ok, waitedMs: Int(Date().timeIntervalSince(start) * 1000),
                        sawHardware: sawHardware, sawSoftwareOnly: sawSoftwareOnly)
        }
        while Date() < deadline {
            let hw = held(.hidSystemState), sw = held(.combinedSessionState)
            if hw { sawHardware = true } else if sw { sawSoftwareOnly = true }
            if !hw && !sw {
                if quietSince == nil { quietSince = Date() }
                if Date().timeIntervalSince(quietSince!) >= 0.15 { return result(true) }
            } else {
                quietSince = nil
            }
            usleep(15_000)
        }
        return result(false)
    }

    // MARK: event construction (creating a CGEvent posts nothing)

    /// Private-state source: its modifier table is independent of the hardware, so a freshly created event carries
    /// no inherited Cmd/Shift (measured: default flags 0x20000000 vs 0x20000100 for hid/combined sources).
    /// Private-state source plus the session event tap is the combination established automation tools use.
    /// Deliberately NO setLocalEventsFilterDuringSuppressionState: suppressing the local keyboard would also eat the Esc-to-stop key.
    public static func makeSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    public static func makeEvents(for key: PlannedKey, source: CGEventSource?) -> [CGEvent] {
        switch key.kind {
        case .shiftDown, .shiftUp:
            // A modifier keycode produces a flagsChanged event; flags must say what is held AFTER the transition.
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: key.kind == .shiftDown) else { return [] }
            e.flags = key.flags
            return [e]
        case .key:
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false) else { return [] }
            // ALWAYS assign flags, including the empty set: an event inherits the source's current modifier state when created.
            down.flags = key.flags; up.flags = key.flags
            if let u = key.unicodeFallback {
                let utf16 = Array(u.utf16)
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            return [down, up]
        }
    }

    // MARK: posting

    /// Posts the plan to the session event tap. Needs Accessibility (check `Permissions.canPostEvents` first).
    /// Run on a background queue. `shouldAbort` is polled before every key (Esc pressed, ScreenConnect no longer frontmost, feature switched off).
    /// Returns the number of plan entries posted.
    public static func post(_ plan: TypingPlan, options: TypingOptions = TypingOptions(),
                            tap: CGEventTapLocation = .cgSessionEventTap, shouldAbort: () -> Bool) -> Int {
        guard CGPreflightPostEventAccess() else { return 0 }
        let source = makeSource()
        var posted = 0
        var shiftIsDown = false
        defer {
            if shiftIsDown, let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: false) {
                e.flags = []; e.post(tap: tap)            // never leave Shift stuck on the guest after an abort
            }
        }
        for key in plan.keys {
            if shouldAbort() { break }
            let events = makeEvents(for: key, source: source)
            switch key.kind {
            case .shiftDown: shiftIsDown = true
            case .shiftUp: shiftIsDown = false
            case .key: break
            }
            for (i, e) in events.enumerated() {
                e.post(tap: tap)
                if key.kind == .key && i == 0 { usleep(options.keyHoldMicros) }
            }
            usleep(options.interKeyMicros)
            posted += 1
        }
        return posted
    }
}
