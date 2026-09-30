// "Which app owns the window under the pointer", no Accessibility / Screen Recording needed.
// Measured: about 0.6 ms per call with 16 windows on screen.
import AppKit
import CoreGraphics

public struct WindowUnderPointer: Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String
    public let bounds: CGRect       // CG global coordinates: origin = top-left of the primary display, y grows DOWN
}

public enum WindowHitTest {
    /// Pointer in CG global coordinates. CGEvent(source:nil).location needs no permission and is already in the
    /// same top-left space CGWindowList uses, so there is no Cocoa y-flip to get wrong.
    public static func pointer() -> CGPoint {
        if let p = CGEvent(source: nil)?.location { return p }
        let m = NSEvent.mouseLocation                                  // Cocoa: origin bottom-left of the PRIMARY screen
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0  // screens[0] is the primary; NSScreen.main is NOT
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }

    /// Frontmost normal (layer 0) window containing the point. The list comes back front-to-back, so occlusion by
    /// another app's window is handled for free. Higher layers (menu bar 24, overlays) are ignored on purpose.
    public static func windowUnder(_ p: CGPoint = pointer()) -> WindowUnderPointer? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for d in raw {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.width > 1, r.height > 1, r.contains(p) else { continue }
            return WindowUnderPointer(windowID: (d[kCGWindowNumber as String] as? CGWindowID) ?? 0,
                                      ownerPID: (d[kCGWindowOwnerPID as String] as? pid_t) ?? 0,
                                      ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                                      bounds: r)
        }
        return nil
    }

    /// The system's corner preview of a screenshot that was just taken is on screen. While it shows, the
    /// screenshot's file has not been saved yet.
    public static func screenshotPreviewVisible() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return raw.contains { ($0[kCGWindowOwnerName as String] as? String) == "screencaptureui" }
    }

    /// The frontmost ordinary window of a process, wherever the pointer is.
    public static func frontWindow(ofPID pid: pid_t) -> WindowUnderPointer? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for d in raw {
            guard (d[kCGWindowOwnerPID as String] as? pid_t) == pid, (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.width >= 200, r.height >= 120 else { continue }
            return WindowUnderPointer(windowID: (d[kCGWindowNumber as String] as? CGWindowID) ?? 0, ownerPID: pid,
                                      ownerName: d[kCGWindowOwnerName as String] as? String ?? "", bounds: r)
        }
        return nil
    }

    /// Is the pointer over a window of one of these bundle ids? Match by PID -> bundle id, not by owner name (names are localizable / reused).
    @MainActor public static func pointerIsOver(bundleIDs: Set<String>) -> (hit: Bool, window: WindowUnderPointer?) {
        guard let w = windowUnder() else { return (false, nil) }
        let bid = NSRunningApplication(processIdentifier: w.ownerPID)?.bundleIdentifier ?? ""
        return (bundleIDs.contains(bid), w)
    }
}
