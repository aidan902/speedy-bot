// Knowing when a chat app is ready to send what was just pasted, by reading its message box through accessibility.
// The box is an AXTextArea; around it sit the composer's own buttons: Send (disabled while the box is empty or a
// picture is still uploading, and hidden altogether in some views when the box is empty), and Stop in its place
// while the app is answering. Everything here is safe to call off the main thread.
import ApplicationServices
import Foundation

/// The CGWindowID behind an accessibility window (not in the public headers; the only way to pin one window).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A Send button found in a chat app. Accessibility elements may be used from any thread.
public struct SendButton: @unchecked Sendable {
    let element: AXUIElement
}

/// What a chat window's message box shows right now.
public struct ComposerState: @unchecked Sendable {
    /// The text in the message box; nil when the box cannot be found or read.
    public let text: String?
    public let sendButton: AXUIElement?
    public let sendEnabled: Bool?
    /// A Stop button shows: the app is still answering.
    public let streaming: Bool
    /// The composer's labelled buttons, "label✓/✗", for the log.
    public let buttons: [String]
    /// The box's own label and placeholder ("Ask anything", "Work with Codex"). ChatGPT reports the placeholder
    /// as the box's value while the box is empty, so a value equal to one of these is an empty box.
    public let emptyTexts: [String]
    /// Pictures shown in the composer (thumbnails of attached screenshots or files).
    public let images: Int
    /// Buttons in the composer other than its own fixed ones (Send, Stop, attach, dictate, voice): attachment
    /// chips bring their own (remove, open). Compared against the count right after a paste, a rise means
    /// something was added to the message.
    public let extras: Int

    static let unreadable = ComposerState(text: nil, sendButton: nil, sendEnabled: nil, streaming: false, buttons: [], emptyTexts: [], images: 0, extras: 0)

    /// What the tech has typed: the text without pasted pictures (U+FFFC) and white space, and "" when the box
    /// only shows its placeholder. nil when unreadable.
    public var typed: String? {
        guard let text else { return nil }
        let t = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if emptyTexts.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return "" }
        return t
    }
}

public enum ChatSend {
    /// Exact Send-button labels (lower-cased), so "Send feedback" or a chat called "Send help" is not one.
    static let sendLabels: Set<String> = ["send", "send message", "send prompt", "submit", "submit message", "send now"]
    /// Exact Stop-button labels shown while the app is answering.
    static let stopLabels: Set<String> = ["stop", "stop streaming", "stop generating", "stop response",
                                          "stop generating response", "stop request", "stop reply"]
    /// The composer's own fixed buttons (measured on ChatGPT), which are not part of a message.
    static let fixedLabels: Set<String> = ["add files and more", "dictate", "start voice chat", "voice mode", "use voice mode"]
    static let timeout: Float = 0.25

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func label(of e: AXUIElement) -> String {
        ((attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: waking ChatGPT's accessibility

    /// Which apps Speedy Bot switched the flag on for. Also written down (by pid and the process's start time), so
    /// that a flag left on by an earlier run (a crash, a Force Quit, the --dump-chat diagnostic) is still known to
    /// be Speedy Bot's to switch off, and one VoiceOver switched on never is.
    private final class Woken: @unchecked Sendable {
        private let lock = NSLock()
        private var askedAt: [pid_t: Date] = [:]
        private var ours: Set<pid_t> = []
        private static let recordKey = "axWokenByUs"
        func claim(_ pid: pid_t, interval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let last = askedAt[pid], Date().timeIntervalSince(last) < interval { return false }
            askedAt[pid] = Date()
            return true
        }
        func markOurs(_ pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            ours.insert(pid)
            var record = Self.record().filter { Int32($0.key).map { Self.startTime(of: $0) != nil } ?? false }
            record[String(pid)] = Self.startTime(of: pid)
            UserDefaults.standard.set(record, forKey: Self.recordKey)
        }
        /// Apps an earlier Speedy Bot switched the flag on for that are still running (the same processes).
        func leftovers() -> [pid_t] {
            Self.record().keys.compactMap { Int32($0) }.filter { wasOurs($0) }
        }
        /// The flag on this app was switched on by an earlier Speedy Bot (same process, not a reused pid).
        func wasOurs(_ pid: pid_t) -> Bool {
            guard let started = Self.startTime(of: pid) else { return false }
            return Self.record()[String(pid)] == started
        }
        /// One app's flag is ours no more (switched off again); true when it was.
        func take(_ pid: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let had = ours.remove(pid) != nil
            askedAt[pid] = nil
            var record = Self.record()
            record[String(pid)] = nil
            UserDefaults.standard.set(record, forKey: Self.recordKey)
            return had
        }
        func takeOurs() -> [pid_t] {
            lock.lock(); defer { lock.unlock() }
            let all = Array(ours)
            ours.removeAll()
            askedAt.removeAll()
            var record = Self.record()
            for pid in all { record[String(pid)] = nil }
            UserDefaults.standard.set(record, forKey: Self.recordKey)
            return all
        }
        private static func record() -> [String: Int] {
            UserDefaults.standard.dictionary(forKey: recordKey) as? [String: Int] ?? [:]
        }
        /// When a process started (seconds since 1970); nil when it is not running.
        private static func startTime(of pid: pid_t) -> Int? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Int(info.pbi_start_tvsec)
        }
    }
    private static let woken = Woken()

    /// An app's accessibility window by its CGWindowID; nil when it has gone.
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first { w in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(w, &id) == .success && id == windowID
        }
    }

    /// The address of the page a browser window shows (its document, else its web area's URL); nil when the browser
    /// does not tell (Chrome, until its accessibility is on).
    public static func pageURL(pid: pid_t, windowID: CGWindowID) -> URL? {
        guard let window = axWindow(pid: pid, windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(window, timeout)
        if let doc = attr(window, "AXDocument") as? String, let url = URL(string: doc), url.host != nil { return url }
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst()
            seen += 1
            AXUIElementSetMessagingTimeout(e, timeout)
            if (attr(e, kAXRoleAttribute) as? String) == "AXWebArea" {
                if let url = attr(e, "AXURL") as? URL { return url }
                continue   // never into the page itself
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }

    /// The window shows more than its frame (a quick look: stops after a few dozen elements).
    public static func isAwake(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else { return false }
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen <= 20 {
            let e = queue.removeFirst()
            seen += 1
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return seen > 20
    }

    /// Wakes and releases run on this one queue, in the order they were asked for.
    private static let flagQueue = DispatchQueue(label: "net.fm.speedybot.ax-flag")

    /// Asks ChatGPT or Claude (Chromium-based) to build its accessibility tree WITHOUT bringing it forward. It shows only its
    /// window frame to accessibility until an assistive app asks, and the request it answers is the flag VoiceOver
    /// sets, AXEnhancedUserInterface (it ignores AXManualAccessibility). Measured: the message box appears about
    /// 2.5 s later and stays readable with the app in the background. Left alone when the flag is already on
    /// (VoiceOver, or an earlier wake, which is taken over when it was Speedy Bot's); asked at most every 30 s per app.
    /// `takeOver`: false for a passing look (the diagnostic), which must not switch off what the running app relies on.
    public static func wakeAccessibility(pid: pid_t, takeOver: Bool = true) {
        flagQueue.async {
            guard woken.claim(pid, interval: 30) else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            if (attr(app, "AXEnhancedUserInterface") as? Bool) == true || (attr(app, "AXManualAccessibility") as? Bool) == true {
                // Already on: ours to switch off later only if an earlier Speedy Bot switched it on.
                if takeOver, woken.wasOurs(pid) { woken.markOurs(pid) }
                return
            }
            // Electron apps (Claude) answer the switch Electron documents for this, AXManualAccessibility; ChatGPT
            // refuses that one and answers the flag VoiceOver sets. The VoiceOver flag also changes how some apps
            // animate their windows, so it is only set where the Electron switch is refused.
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            woken.markOurs(pid)
        }
    }

    /// At launch: a flag an earlier Speedy Bot left on (a crash, a Force Quit) is taken back as this one's, so the
    /// usual release (nothing waiting, auto-send off, quitting) switches it off.
    public static func adoptLeftovers() {
        flagQueue.async {
            for pid in woken.leftovers() {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, timeout)
                if (attr(app, "AXEnhancedUserInterface") as? Bool) == true { woken.markOurs(pid) }
            }
        }
    }

    /// Switches the flag off again on every app Speedy Bot switched it on for (auto-send off, or quitting): the app
    /// then stops keeping its whole page available to accessibility. `wait`: done before returning (at quit).
    /// Switches the flag off again for one app, if this Speedy Bot switched it on (a browser woken for one paste).
    public static func releaseAccessibility(pid: pid_t, wait: Bool = false) {
        let work: @Sendable () -> Void = {
            guard woken.take(pid) else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        if wait { flagQueue.sync(execute: work) } else { flagQueue.async(execute: work) }
    }

    public static func releaseAccessibility(wait: Bool = false) {
        let work: @Sendable () -> Void = {
            for pid in woken.takeOurs() {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, timeout)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }
        if wait { flagQueue.sync(execute: work) } else { flagQueue.async(execute: work) }
    }

    /// Presses the button itself, which works with the app in the background. A slow answer is not taken as a
    /// refusal here: the caller confirms the send by watching the box.
    public static func press(_ button: SendButton) -> Bool {
        AXUIElementSetMessagingTimeout(button.element, 1.0)
        return AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
    }

    // MARK: diagnostics (--dump-chat)

    /// Labelled buttons of the front window, and whether a Send / Stop button is among them.
    public static func scanWindow(pid: pid_t) -> (tree: Bool, send: Bool?, streaming: Bool, buttons: [String]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else { return (false, nil, false, []) }
        var queue = [window], visited = 0, send: Bool?, streaming = false, buttons: [String] = []
        while !queue.isEmpty, visited < 8000 {
            let e = queue.removeFirst()
            visited += 1
            if (attr(e, kAXRoleAttribute) as? String) == "AXButton" {
                let l = label(of: e)
                if sendLabels.contains(l) { send = (attr(e, kAXEnabledAttribute) as? Bool) == true }
                if stopLabels.contains(l) { streaming = true }
                if !l.isEmpty { buttons.append(l) }
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return (visited > 20, send, streaming, buttons)
    }
}

/// The message box of ONE chat window (the one a screenshot was pasted into), found once and then re-read cheaply:
/// its text, and the composer's own buttons around it. Not shared between threads at the same time.
public final class Composer: @unchecked Sendable {
    public let pid: pid_t
    public let windowID: CGWindowID
    private var textArea: AXUIElement?
    private var root: AXUIElement?
    /// How many times the box had to be found again after it was first found: the page replaced it (a different
    /// conversation, a new chat). Anything waiting to send treats that as "this is not the box I pasted into".
    public private(set) var relocations = 0
    private var foundOnce = false
    /// Text a website's box shows when empty that a browser reports as its contents (Chrome reads grok.com's
    /// placeholder "Ask, create images, or build anything…" as the box's value): counted as empty from now on.
    private var learnedEmpty: [String] = []

    /// The box reads `text` while it is known to be empty: that text is its placeholder.
    public func learnEmpty(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !learnedEmpty.contains(t) { learnedEmpty.append(t) }
    }

    public init(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid
        self.windowID = windowID
    }

    /// The window by its CGWindowID; nil when it has gone (or another window is not this one).
    private func window() -> AXUIElement? { ChatSend.axWindow(pid: pid, windowID: windowID) }

    /// Experimental (--test-background-paste): makes this window the app's main window and the message box its
    /// focused element through accessibility, without activating the app. Returns the two results.
    public func focusQuietly() -> (main: AXError, focus: AXError) {
        if textArea == nil { locate() }
        guard let window = window(), let box = textArea else { return (.failure, .failure) }
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focus = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return (main, focus)
    }

    /// Puts the keyboard in the message box through accessibility (a chat website in a browser: the keyboard may be
    /// anywhere on the page, or in the address bar). True when the box took it.
    public func focusBox() -> Bool {
        if textArea == nil { locate() }
        guard let box = textArea else { return false }
        if (ChatSend.attr(box, kAXFocusedAttribute) as? Bool) == true { return true }
        return AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Finds the message box: the focused text area of the window, else the last one (the box is at the bottom),
    /// and the composer around it (a few levels up).
    private func locate() {
        textArea = nil
        root = nil
        guard let window = window() else { return }
        var queue = [window]
        var visited = 0
        var last: AXUIElement?
        var focused: AXUIElement?
        while !queue.isEmpty, visited < 15000, focused == nil {
            let e = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(e, ChatSend.timeout)
            if (ChatSend.attr(e, kAXRoleAttribute) as? String) == "AXTextArea" {
                last = e
                if (ChatSend.attr(e, kAXFocusedAttribute) as? Bool) == true { focused = e }
            }
            if let kids = ChatSend.attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        guard let box = focused ?? last else { return }
        var up = box
        for _ in 0..<4 {
            guard let parent = ChatSend.attr(up, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let p = parent as! AXUIElement
            if (ChatSend.attr(p, kAXRoleAttribute) as? String) == "AXWindow" { break }
            up = p
        }
        textArea = box
        root = up
        if foundOnce { relocations += 1 }
        foundOnce = true
    }

    /// What the box shows now. Re-finds the box when the page has replaced it.
    public func read() -> ComposerState {
        for attempt in 0..<2 {
            if textArea == nil { locate() }
            guard let box = textArea, let root else { return .unreadable }
            AXUIElementSetMessagingTimeout(box, ChatSend.timeout)
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(box, kAXValueAttribute as CFString, &value)
            if err == .invalidUIElement && attempt == 0 { textArea = nil; continue }
            guard err == .success || err == .noValue else { return .unreadable }
            let text = (value as? String) ?? ""
            let emptyTexts = [kAXPlaceholderValueAttribute as String, kAXDescriptionAttribute as String, kAXTitleAttribute as String]
                .compactMap { ChatSend.attr(box, $0) as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var queue = [root]
            var visited = 0
            var send: AXUIElement?
            var streaming = false
            var buttons: [String] = []
            var images = 0
            var extras = 0
            while !queue.isEmpty, visited < 800 {
                let e = queue.removeFirst()
                visited += 1
                AXUIElementSetMessagingTimeout(e, ChatSend.timeout)
                let role = ChatSend.attr(e, kAXRoleAttribute) as? String
                if role == "AXImage" { images += 1 }
                if role == "AXButton" {
                    let l = ChatSend.label(of: e)
                    if ChatSend.sendLabels.contains(l) { send = e }
                    if ChatSend.stopLabels.contains(l) { streaming = true }
                    if !ChatSend.sendLabels.contains(l), !ChatSend.stopLabels.contains(l), !ChatSend.fixedLabels.contains(l) { extras += 1 }
                    buttons.append("\(l.isEmpty ? "(no label)" : l)\((ChatSend.attr(e, kAXEnabledAttribute) as? Bool) == true ? "✓" : "✗")")
                }
                if let kids = ChatSend.attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
            let enabled = send.flatMap { ChatSend.attr($0, kAXEnabledAttribute) as? Bool }
            return ComposerState(text: text, sendButton: send, sendEnabled: enabled, streaming: streaming, buttons: buttons,
                                 emptyTexts: emptyTexts + learnedEmpty, images: images, extras: extras)
        }
        return .unreadable
    }
}
