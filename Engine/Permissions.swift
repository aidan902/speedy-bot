// TCC status checks. Everything here is READ-ONLY unless the name says "request".
import ApplicationServices
import AppKit
import Carbon.HIToolbox

public enum Permissions {
    /// Accessibility (kTCCServiceAccessibility). Needed for: posting CGEvents to other apps, AXUIElement calls, active event taps.
    public static var accessibilityTrusted: Bool {
        if AXIsProcessTrusted() { return true }
        // AXIsProcessTrusted has been seen answering false on macOS 27 for a process whose accessibility calls
        // work, so ask the question for real before telling the tech the permission is missing.
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success
    }

    /// Same check through the CoreGraphics door (kTCCServicePostEvent; satisfied by the Accessibility switch).
    public static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Input Monitoring (kTCCServiceListenEvent). Only needed for a listen-only CGEventTap / keyboard global monitors. Not needed by the recommended design.
    public static var canListenEvents: Bool { CGPreflightListenEventAccess() }

    /// Screen Recording. NOT needed: owner name / pid / bounds / layer come back from CGWindowList without it; only kCGWindowName is withheld.
    public static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    /// True while some app holds Secure Event Input (password field focus). Event taps see no keys then; posting still goes out.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Shows the system "would like to control this computer using accessibility features" alert ONCE and adds the app (unticked)
    /// to System Settings > Privacy & Security > Accessibility. Call only from an explicit user action (a button in the app window).
    @MainActor @discardableResult
    public static func requestAccessibilityPrompt() -> Bool {
        // String literal instead of kAXTrustedCheckOptionPrompt: the global is an Unmanaged<CFString> var, which Swift 6 flags as non-Sendable shared state.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Deep link to the Accessibility pane (works on macOS 13+; user still has to flip the switch).
    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Pasteboard privacy (macOS 15.4+): programmatic reads of the general pasteboard can raise a "paste from other apps" alert.
    /// `.alwaysAllow` means no alert. Reading changeCount/types never alerts; reading data (string(forType:)) may.
    @MainActor public static var pasteboardAccess: String {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .default: return "default"
            case .ask: return "ask"
            case .alwaysAllow: return "alwaysAllow"
            case .alwaysDeny: return "alwaysDeny"
            @unknown default: return "unknown"
            }
        }
        return "n/a"
    }
}
