// Bring the target app's window forward and paste the clipboard into it.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum PasteResult: Sendable, Equatable {
    case pasted
    case notTrusted            // Accessibility not granted
    case activationTimedOut    // the target never became frontmost
    case clipboardChanged      // the user copied something else meanwhile
    case otherFieldFocused     // keyboard focus is in some other text field of the target
    case modifiersHeld         // the user is holding Cmd/Shift/Option/Control
    case pointerLeft           // the pointer moved off the target before the paste
}

/// The CGWindowID behind an accessibility window. Not in the public headers, but it is the only way to tell
/// apart two windows of one app that sit at exactly the same frame (ChatGPT opens new windows that way).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
public enum Paster {
    // MARK: AX helpers

    /// The messaging timeout belongs to the element it is set on, so every element that is asked something gets
    /// one: a busy target must never hang this app's main thread for the 6-second system default.
    private static let axTimeout: Float = 0.25

    static func copy(_ e: AXUIElement, _ name: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(e, axTimeout)
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = copy(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, axTimeout)
        return ax
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = copy(window, kAXPositionAttribute), let s = copy(window, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// The accessibility window for a window found by the pointer hit test: by window id, else by frame.
    static func axWindow(pid: pid_t, for target: WindowUnderPointer) -> AXUIElement? {
        guard let wins = copy(appElement(pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        if target.windowID != 0, let exact = wins.first(where: { windowID(of: $0) == target.windowID }) { return exact }
        return wins.first { w in
            if (copy(w, kAXMinimizedAttribute) as? Bool) == true { return false }
            guard let f = frame(of: w) else { return false }
            return abs(f.minX - target.bounds.minX) < 2 && abs(f.minY - target.bounds.minY) < 2
                && abs(f.width - target.bounds.width) < 2 && abs(f.height - target.bounds.height) < 2
        }
    }

    /// Title of the focused window of an app (nil when the app does not expose one).
    public static func focusedWindowTitle(pid: pid_t) -> String? {
        guard let w = element(appElement(pid), kAXFocusedWindowAttribute) else { return nil }
        return copy(w, kAXTitleAttribute) as? String
    }

    /// Role of the keyboard-focused element (ChatGPT's message box is an AXTextArea described "Ask ChatGPT").
    public static func focusedElementRole(pid: pid_t) -> String? {
        guard let f = element(appElement(pid), kAXFocusedUIElementAttribute) else { return nil }
        return copy(f, kAXRoleAttribute) as? String
    }

    /// Which process owns whatever is REALLY under this point, as accessibility sees it. Unlike the window-list
    /// hit test this notices a menu, popover or panel floating over the window.
    public static func ownerPID(at point: CGPoint) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(hit, &pid) == .success ? pid : nil
    }

    // MARK: activation

    /// Raise one specific window and make its app frontmost. Needs Accessibility, which the app holds anyway.
    static func raise(pid: pid_t, window target: WindowUnderPointer) {
        if let w = axWindow(pid: pid, for: target) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(appElement(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// LaunchServices is allowed to activate on behalf of a background app, which
    /// NSRunningApplication.activate() is not guaranteed to do on macOS 14+.
    static func activateViaWorkspace(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { _ = app.activate(options: []); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }

    // MARK: the paste

    /// Synthetic Cmd+V: private-state source, flags set on BOTH events, posted to the session tap.
    /// The key is the one that means V while Command is held on the current layout.
    static func postCommandV() {
        let vKey = LayoutKeyMap.keyCodeWithCommand(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let src = TextTyper.makeSource()
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)   // 0x8: left-Command device bit
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Full sequence. `expectedChangeCount` is the pasteboard changeCount captured when the screenshot was
    /// detected: if anything else has been copied since, nothing is pasted.
    /// `refuseOtherTextFields`: when the target's keyboard focus sits in a single-line field (search box, rename
    /// field), leave the screenshot on the clipboard instead of pasting into the wrong place.
    /// `stillOnTarget` is asked at the last moment; it must be quick.
    public static func paste(into app: NSRunningApplication, window: WindowUnderPointer, expectedChangeCount: Int,
                             refuseOtherTextFields: Bool, stillOnTarget: () -> Bool,
                             settle: Duration = .milliseconds(180),
                             activationTimeout: Duration = .milliseconds(1500)) async -> PasteResult {
        guard Permissions.accessibilityTrusted else { return .notTrusted }
        guard NSPasteboard.general.changeCount == expectedChangeCount else { return .clipboardChanged }
        let pid = app.processIdentifier

        let started = ContinuousClock.now
        var timeline = ""
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        // Already in front, with the target window on top of its own windows: nothing to raise. Every
        // accessibility call into a web-based app can take a noticeable moment, so none are made for nothing.
        if !(wasFrontmost && WindowHitTest.frontWindow(ofPID: pid)?.windowID == window.windowID) {
            raise(pid: pid, window: window)
            timeline += " raise=\(ms(since: started))"
        }
        if !wasFrontmost {
            let clock = ContinuousClock(); let start = clock.now
            var triedWorkspace = false
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                let waited = clock.now - start
                if waited > activationTimeout { return .activationTimedOut }
                if !triedWorkspace, waited > .milliseconds(300) { triedWorkspace = true; activateViaWorkspace(app) }
                try? await Task.sleep(for: .milliseconds(15))
            }
            // A web-based app restores keyboard focus to its page a moment after the window becomes key.
            try? await Task.sleep(for: settle)
            timeline += " activated=\(ms(since: started))"
        }

        // A held modifier would turn Cmd+V into something else (Cmd+Shift+V is "paste and match style").
        var spins = 0
        while TextTyper.physicalModifiersDown() {
            spins += 1
            if spins > 100 { return .modifiersHeld }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // The one slow question (it talks to the target app) comes first...
        if refuseOtherTextFields, let role = focusedElementRole(pid: pid),
           ["AXTextField", "AXSearchField", "AXComboBox", "AXSecureTextField"].contains(role) {
            return .otherFieldFocused
        }
        timeline += " focusCheck=\(ms(since: started))"
        // ...then let the run loop catch up, and check everything that matters with nothing slow in between,
        // so the keystroke cannot land in an app the tech switched to while this was waiting.
        try? await Task.sleep(for: .milliseconds(10))
        guard !TextTyper.physicalModifiersDown() else { return .modifiersHeld }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .activationTimedOut }
        guard NSPasteboard.general.changeCount == expectedChangeCount else { return .clipboardChanged }
        guard stillOnTarget() else { return .pointerLeft }
        postCommandV()
        SpeedyShared.log.notice("paste timeline (ms):\(timeline, privacy: .public) cmdV=\(ms(since: started))")
        return .pasted
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
