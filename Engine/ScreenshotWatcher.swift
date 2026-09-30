// Detects "the user just took a screenshot" by watching the general pasteboard.
// Fingerprint measured on macOS 27.0.1: a screenshot sent to the clipboard is exactly ONE item whose only
// declared type is public.png (no string / html / file-url flavours, which every other image copy carries).
import AppKit

@MainActor
public final class PasteboardWatcher {
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var emptyRetries = 0
    private let onChange: (_ changeCount: Int, _ isScreenshot: Bool) -> Void
    /// One poll costs well under a microsecond. The controller remembers where the pointer was before a change shows up.
    public var interval: TimeInterval = 0.25

    public init(onChange: @escaping (_ changeCount: Int, _ isScreenshot: Bool) -> Void) { self.onChange = onChange }

    /// public.png is what the system writes; jpeg/heic cover a customised `type` screenshot preference.
    private static let screenshotTypes: Set<NSPasteboard.PasteboardType> = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// Metadata only. It never reads pasteboard DATA, so it cannot raise the "paste from other apps" alert.
    public static func looksLikeScreenshot(_ pb: NSPasteboard = .general) -> Bool {
        guard let items = pb.pasteboardItems, items.count == 1 else { return false }
        let types = items[0].types
        return types.count == 1 && screenshotTypes.contains(types[0])
    }

    public func start() {
        stop()
        lastChange = NSPasteboard.general.changeCount
        emptyRetries = 0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let pb = NSPasteboard.general
        let c = pb.changeCount
        if c == lastChange {
            // A change that was seen while the clipboard was still empty: look again now that it has settled.
            guard emptyRetries > 0 else { return }
            if (pb.pasteboardItems ?? []).isEmpty {
                emptyRetries -= 1
                if emptyRetries == 0 { onChange(c, false) }
                return
            }
            emptyRetries = 0
            onChange(c, Self.looksLikeScreenshot(pb))
            return
        }
        lastChange = c
        // An app clears the clipboard first and writes a moment later; the count only moves on the clear.
        // Caught in between, the clipboard is empty: that is "not written yet", not "not a screenshot".
        if (pb.pasteboardItems ?? []).isEmpty {
            emptyRetries = 3
            return
        }
        emptyRetries = 0
        onChange(c, Self.looksLikeScreenshot(pb))
    }
}
