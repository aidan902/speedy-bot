// Knowing when a chat app is ready to send what was just pasted, by watching its compose area through
// accessibility. A chat app (ChatGPT, Claude) shows a Send button that is disabled while the box is empty or a
// picture is still uploading, and enabled the moment the message can go; while it is answering, that button is
// replaced by a Stop button. So "ready to send" is: a Send button exists and is enabled, and no Stop button shows.
// Everything here is safe to call off the main thread.
import ApplicationServices
import Foundation

/// A Send button found in a chat app. Accessibility elements may be used from any thread.
public struct SendButton: @unchecked Sendable {
    let element: AXUIElement
}

/// What one look at the compose area found.
public struct ComposerScan: @unchecked Sendable {
    public let sendButton: AXUIElement?
    /// nil when there is no Send button (or it could not be read).
    public let sendEnabled: Bool?
    /// A Stop button is showing: the app is still answering, so nothing should be sent yet.
    public let streaming: Bool
    /// The window exposed its contents at all (a web-based app that has not built its tree shows only its frame).
    public let hasTree: Bool
    /// Labelled buttons, "label✓/✗", a few, for the log when a send does not go through.
    public let inventory: [String]

    /// A Send button or a Stop button was found: the compose area can be read.
    public var readable: Bool { sendButton != nil || streaming }
}

public enum ChatSend {
    /// Exact Send-button labels (lower-cased), so "Send feedback" or a chat called "Send help" is not one.
    private static let sendLabels: Set<String> = ["send", "send message", "send prompt", "submit", "submit message", "send now"]
    /// Exact Stop-button labels shown while the app is answering.
    private static let stopLabels: Set<String> = ["stop", "stop streaming", "stop generating", "stop response",
                                                  "stop generating response", "stop request", "stop reply"]
    private static let timeout: Float = 0.25

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    // MARK: waking a web-based app's accessibility

    private final class WokenList: @unchecked Sendable {
        private let lock = NSLock()
        private var at: [pid_t: Date] = [:]
        /// True when this pid was not asked within `interval`, and records the ask.
        func claim(_ pid: pid_t, interval: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let last = at[pid], Date().timeIntervalSince(last) < interval { return false }
            at[pid] = Date()
            return true
        }
    }
    private static let woken = WokenList()

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

    /// Asks a Chromium-based chat app (ChatGPT, Claude) to build its accessibility tree, WITHOUT bringing it
    /// forward. Such apps show only their window frame to accessibility until an assistive app asks; the request
    /// they answer is the flag VoiceOver sets, AXEnhancedUserInterface (measured: ChatGPT's compose area appears
    /// about 2.5 s later; it ignores AXManualAccessibility). Left alone when the tree is already there, and asked
    /// at most every 30 seconds per app.
    public static func wakeAccessibility(pid: pid_t) {
        guard woken.claim(pid, interval: 30), !isAwake(pid: pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: reading the compose area

    /// One walk of the front window: the last Send button, whether a Stop button is showing, and a short
    /// inventory of labelled buttons. The last Send button wins because the compose box is at the bottom.
    public static func scanComposer(pid: pid_t) -> ComposerScan {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else {
            return ComposerScan(sendButton: nil, sendEnabled: nil, streaming: false, hasTree: false, inventory: [])
        }
        var queue = [window]
        var visited = 0
        var send: AXUIElement?
        var streaming = false
        var inventory: [String] = []
        while !queue.isEmpty, visited < 6000 {
            let e = queue.removeFirst()
            visited += 1
            if (attr(e, kAXRoleAttribute) as? String) == "AXButton" {
                let label = ((attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !label.isEmpty {
                    let isSend = sendLabels.contains(label), isStop = stopLabels.contains(label)
                    if isSend { send = e }
                    if isStop { streaming = true }
                    // The composer's own buttons always make the log; the sidebar only fills the first slots.
                    if isSend || isStop || inventory.count < 20 {
                        inventory.append("\(label)\((attr(e, kAXEnabledAttribute) as? Bool) == true ? "✓" : "✗")")
                    }
                }
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return ComposerScan(sendButton: send, sendEnabled: send.flatMap(isEnabled), streaming: streaming,
                            hasTree: visited > 20, inventory: inventory)
    }

    /// nil when the button has gone away (the page re-drew it) or cannot be read.
    public static func isEnabled(_ button: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(button, timeout)
        return attr(button, kAXEnabledAttribute) as? Bool
    }

    /// Presses the button itself, which works with the app in the background. False when the app did not take it.
    public static func press(_ button: SendButton) -> Bool {
        AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
    }
}
