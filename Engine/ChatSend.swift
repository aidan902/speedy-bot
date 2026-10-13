// Knowing when a chat app is ready to send what was just pasted, by watching its compose area through
// accessibility. A chat app (ChatGPT, Claude) shows a Send button that is disabled while the box is empty
// or a picture is still uploading, and enabled the moment the message can go; while it is answering, that
// button is replaced by a Stop button. So "ready to send" is: a Send button exists and is enabled, and no
// Stop button is showing. Everything here is safe to call off the main thread.
import ApplicationServices
import Foundation

/// A Send button found in a chat app. Accessibility elements may be used from any thread.
public struct SendButton: @unchecked Sendable {
    let element: AXUIElement
}

/// What one look at the compose area found.
public struct ComposerScan: @unchecked Sendable {
    public let sendButton: AXUIElement?
    /// A Stop button is showing: the app is still answering, so nothing should be sent yet.
    public let streaming: Bool
    /// Were any accessibility elements exposed at all (a web-based app that has not woken its tree shows none).
    public let hasTree: Bool
    /// Labelled buttons, "role:label(on/off)", a few, for the log when a send does not go through.
    public let inventory: [String]
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

    /// Makes a web-based app (ChatGPT is one) build its accessibility tree: Chromium only exposes its content
    /// once it has been asked to be frontmost through accessibility, and tears it down again when idle.
    public static func wakeAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// One walk of the front window: the last Send button, whether a Stop button is showing, and a short
    /// inventory of labelled buttons. The last Send button wins because the compose box is at the bottom.
    public static func scanComposer(pid: pid_t) -> ComposerScan {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else {
            return ComposerScan(sendButton: nil, streaming: false, hasTree: false, inventory: [])
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
        return ComposerScan(sendButton: send, streaming: streaming, hasTree: visited > 20, inventory: inventory)
    }

    /// The Send button of the app's front window, or nil. Kept for the pre-paste "is there a draft?" check.
    public static func findSendButton(pid: pid_t) -> AXUIElement? { scanComposer(pid: pid).sendButton }

    /// nil when the button has gone away (the page re-drew it) or cannot be read.
    public static func isEnabled(_ button: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(button, timeout)
        return attr(button, kAXEnabledAttribute) as? Bool
    }

    public enum Readiness: Sendable { case ready, timedOut, unknownApp }

    /// Waits until the message can be sent: a Send button is enabled and the app is not mid-answer. While the
    /// app is still answering (a Stop button shows), it keeps waiting. Returns `unknownApp` only when no
    /// compose area ever appears (an app whose Send button cannot be read), so the caller can fall back.
    /// `onScan` is handed each look, for logging.
    public static func waitUntilReady(pid: pid_t, timeout seconds: TimeInterval,
                                      onScan: (@Sendable (ComposerScan) -> Void)? = nil) async -> (Readiness, SendButton?) {
        wakeAccessibility(pid: pid)
        let deadline = Date().addingTimeInterval(seconds)
        var sawComposer = false
        var emptyLooks = 0
        var last = ComposerScan(sendButton: nil, streaming: false, hasTree: false, inventory: [])
        while Date() < deadline {
            let scan = scanComposer(pid: pid)
            last = scan
            if let b = scan.sendButton, !scan.streaming, isEnabled(b) == true { return (.ready, SendButton(element: b)) }
            if scan.sendButton != nil || scan.streaming {
                sawComposer = true
                emptyLooks = 0
            } else {
                emptyLooks += 1
                // Nothing to send and nothing answering: give a web app a few seconds to build its tree, then
                // keep the app awake and try again.
                if emptyLooks % 12 == 0 { wakeAccessibility(pid: pid) }
                if !sawComposer, emptyLooks >= 24 { onScan?(scan); return (.unknownApp, nil) }   // ~6 s, never saw a composer
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        onScan?(last)
        return (sawComposer || last.sendButton != nil ? .timedOut : .unknownApp, last.sendButton.map { SendButton(element: $0) })
    }

    /// Presses the button itself. False when the app did not take it.
    public static func press(_ button: SendButton) -> Bool {
        AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
    }
}
