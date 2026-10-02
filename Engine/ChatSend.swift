// Knowing when a chat app is ready to send what was just pasted, by watching its Send button through
// accessibility: the button is disabled while the message box is empty or a picture is still uploading, and
// becomes enabled the moment the message can go. Everything here is safe to call off the main thread.
import ApplicationServices
import Foundation

/// A Send button found in a chat app. Accessibility elements may be used from any thread.
public struct SendButton: @unchecked Sendable {
    let element: AXUIElement
}

public enum ChatSend {
    /// What the Send button is called in the chat apps (matched exactly, lower-cased, so "Send feedback" is not it).
    private static let labels: Set<String> = ["send", "send message", "send prompt", "submit", "submit message"]
    private static let timeout: Float = 0.25

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// The Send button of the app's front window, or nil when there is none to be found (an app this does not know).
    public static func findSendButton(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else { return nil }
        var queue = [window]
        var visited = 0
        var match: AXUIElement?
        while !queue.isEmpty, visited < 5000 {
            let e = queue.removeFirst()
            visited += 1
            if (attr(e, kAXRoleAttribute) as? String) == "AXButton" {
                let names = [attr(e, kAXDescriptionAttribute) as? String, attr(e, kAXTitleAttribute) as? String]
                if names.contains(where: { $0.map { labels.contains($0.lowercased()) } ?? false }) { match = e }   // the last one: the message box is at the bottom
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return match
    }

    /// nil when the button has gone away (the page re-drew it) or cannot be read.
    public static func isEnabled(_ button: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(button, timeout)
        return attr(button, kAXEnabledAttribute) as? Bool
    }

    public enum Readiness: Sendable { case ready, timedOut, unknownApp }

    /// Waits until the Send button is enabled, checking about twelve times a second.
    public static func waitUntilReady(pid: pid_t, timeout seconds: TimeInterval) async -> (Readiness, SendButton?) {
        let deadline = Date().addingTimeInterval(seconds)
        var button = findSendButton(pid: pid)
        if button == nil {
            // Give the page a moment: the button may only appear once there is something to send.
            try? await Task.sleep(for: .milliseconds(400))
            button = findSendButton(pid: pid)
            if button == nil { return (.unknownApp, nil) }
        }
        while Date() < deadline {
            if let b = button, let enabled = isEnabled(b) {
                if enabled { return (.ready, SendButton(element: b)) }
            } else {
                button = findSendButton(pid: pid)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return (.timedOut, button.map(SendButton.init))
    }

    /// Presses the button itself. False when the app did not take it.
    public static func press(_ button: SendButton) -> Bool {
        AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
    }
}
