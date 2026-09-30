import AppKit

/// Feature A: a fresh screenshot is pasted into ChatGPT, but only once the pointer moves back onto the
/// ChatGPT window. One paste per screenshot, no click needed.
///
///   screenshot lands on the clipboard -> ARMED
///   pointer was somewhere that is not ChatGPT, then comes to rest on a ChatGPT window -> bring it forward, Cmd+V
///   anything else copied, or three minutes pass -> disarmed, nothing is pasted
///
/// The same clipboard watcher also feeds "save screenshots for documentation" through `onScreenshot`.
@MainActor
final class ScreenshotPasteController {
    private struct Armed { let changeCount: Int; let at: Date }

    private unowned let state: AppState
    private lazy var watcher = PasteboardWatcher { [weak self] count, isScreenshot in
        self?.clipboardChanged(count, isScreenshot: isScreenshot)
    }
    private var pointerTimer: Timer?
    private var hoverTimer: Timer?
    private var armed: Armed?
    private var sawPointerElsewhere = false
    private var lastSeenOffChatGPT = Date.distantPast
    private var lastPointer = CGPoint.zero
    private var dwellTicks = 0
    private var loggedOccluder = false
    private var pasting = false
    private(set) var running = false
    /// Hover-paste itself. The watcher also runs for saving screenshots, so this can be off while `running`.
    var pasteEnabled = true { didSet { if !pasteEnabled { disarm("paste switched off") } } }
    /// Called for every screenshot that lands on the clipboard, before it is armed for pasting.
    var onScreenshot: (() -> Void)?

    /// A screenshot older than this is never pasted.
    private let expiry: TimeInterval = 180
    private let tick: TimeInterval = 0.1
    /// The pointer has to REST on ChatGPT: this many ticks in a row, moving less than `restRadius` each tick.
    /// Crossing the window on the way to something else does not count.
    private let dwellNeeded = 3
    private let restRadius: CGFloat = 16
    /// A screenshot reaches the clipboard up to about a second after the capture. If the pointer was off
    /// ChatGPT within this long before arming, it was off ChatGPT when the screenshot was taken.
    private let elsewhereMemory: TimeInterval = 1.2

    init(state: AppState) { self.state = state }

    func start() {
        guard !running else { return }
        running = true
        watcher.start()
        // Remember where the pointer has been BEFORE a screenshot arrives, so a quick flick from the capture
        // straight onto ChatGPT still counts as "moved back to chat".
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        pointerTimer?.invalidate(); pointerTimer = nil
        disarm("stopped")
    }

    private func samplePointer() {
        guard pasteEnabled, armed == nil else { return }   // while armed the hover timer keeps this up to date
        if chatGPTUnderPointer() == nil { lastSeenOffChatGPT = Date() }
    }

    // MARK: arming

    private func clipboardChanged(_ count: Int, isScreenshot: Bool) {
        guard isScreenshot else {
            // Types only (never the contents): shows why a capture was not recognised as a screenshot.
            let items = NSPasteboard.general.pasteboardItems ?? []
            let types = items.first?.types.map(\.rawValue).joined(separator: ", ") ?? "none"
            SpeedyShared.log.info("clipboard change \(count) is not a screenshot: \(items.count) item(s), types [\(types, privacy: .public)]")
            disarm("clipboard changed")
            return
        }
        onScreenshot?()
        guard pasteEnabled else { return }
        armed = Armed(changeCount: count, at: Date())
        sawPointerElsewhere = Date().timeIntervalSince(lastSeenOffChatGPT) < elsewhereMemory
        dwellTicks = 0
        loggedOccluder = false
        state.armed = true
        SpeedyShared.log.notice("screenshot on clipboard (change \(count)); waiting for the pointer to reach ChatGPT; pointer was elsewhere=\(self.sawPointerElsewhere)")
        startHoverTimer()
    }

    private func disarm(_ why: String) {
        hoverTimer?.invalidate(); hoverTimer = nil
        guard armed != nil else { return }
        armed = nil
        state.armed = false
        SpeedyShared.log.notice("disarmed: \(why, privacy: .public)")
    }

    private func startHoverTimer() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    // MARK: hover

    /// ChatGPT desktop app. The current app and Codex.app share the bundle id com.openai.codex, so the name is
    /// checked as well; helper processes ("ChatGPT Computer Use", "ChatGPTHelper") have other bundle ids.
    static func isChatGPT(_ app: NSRunningApplication) -> Bool {
        switch app.bundleIdentifier {
        case "com.openai.chat": return true
        case "com.openai.codex":
            return app.bundleURL?.deletingPathExtension().lastPathComponent == "ChatGPT" || app.localizedName == "ChatGPT"
        default: return false
        }
    }

    private func chatGPTUnderPointer(_ point: CGPoint = WindowHitTest.pointer()) -> (app: NSRunningApplication, window: WindowUnderPointer)? {
        guard let w = WindowHitTest.windowUnder(point), w.bounds.width >= 200, w.bounds.height >= 120,
              let app = NSRunningApplication(processIdentifier: w.ownerPID), Self.isChatGPT(app) else { return nil }
        return (app, w)
    }

    private func hoverTick() {
        guard let armed, !pasting else { return }
        if Date().timeIntervalSince(armed.at) > expiry { disarm("expired"); return }
        if NSPasteboard.general.changeCount != armed.changeCount { disarm("clipboard changed"); return }

        let point = WindowHitTest.pointer()
        let moved = hypot(point.x - lastPointer.x, point.y - lastPointer.y)
        lastPointer = point

        guard let target = chatGPTUnderPointer(point) else {
            sawPointerElsewhere = true
            lastSeenOffChatGPT = Date()
            dwellTicks = 0
            return
        }
        // "Moves back to chat": the pointer must have been somewhere else since the screenshot was taken.
        guard sawPointerElsewhere else { return }
        // Still moving, or dragging something across the window, is not "coming back to chat".
        if moved > restRadius
            || CGEventSource.buttonState(.hidSystemState, button: .left) || CGEventSource.buttonState(.hidSystemState, button: .right) {
            dwellTicks = 0
            return
        }
        dwellTicks += 1
        guard dwellTicks >= dwellNeeded else { return }
        // The window list only knows ordinary windows. A menu, popover or panel floating over ChatGPT belongs
        // to someone else, and accessibility can see that.
        if let owner = Paster.ownerPID(at: point), owner != target.app.processIdentifier {
            if !loggedOccluder {
                loggedOccluder = true
                SpeedyShared.log.notice("pointer is over ChatGPT but process \(owner) has something on top of it; not pasting there")
            }
            dwellTicks = 0
            return
        }
        paste(into: target.app, window: target.window, armed: armed)
    }

    // MARK: paste

    private func paste(into app: NSRunningApplication, window: WindowUnderPointer, armed: Armed) {
        pasting = true
        hoverTimer?.invalidate(); hoverTimer = nil
        Task { @MainActor in
            // Only the current ChatGPT app is known to route a paste to its message box from anywhere in the
            // window; its search and rename fields are the places a picture must not go.
            let result = await Paster.paste(
                into: app, window: window, expectedChangeCount: armed.changeCount,
                refuseOtherTextFields: app.bundleIdentifier == "com.openai.codex",
                stillOnTarget: { WindowHitTest.windowUnder()?.windowID == window.windowID })
            self.pasting = false
            SpeedyShared.log.notice("paste result: \(String(describing: result), privacy: .public)")

            // A newer screenshot was taken while this one was being pasted: it is the one that is armed now.
            guard self.armed?.changeCount == armed.changeCount else {
                if self.armed != nil { self.dwellTicks = 0; self.startHoverTimer() }
                return
            }
            switch result {
            case .pasted:
                self.disarm("pasted")
                Toast.show("Screenshot pasted into ChatGPT", seconds: 1.4)
            case .notTrusted:
                self.disarm("no accessibility")
                Toast.show("Speedy Bot needs Accessibility permission to paste", seconds: 3)
                self.state.showWindow?()
            case .clipboardChanged:
                self.disarm("clipboard changed")
            case .otherFieldFocused:
                self.disarm("other field focused")
                Toast.show("Screenshot is on the clipboard. Click the message box and press ⌘V", seconds: 3.5)
            case .pointerLeft:
                // The pointer has been elsewhere again; pasting waits for it to come back.
                self.sawPointerElsewhere = true
                self.dwellTicks = 0
                self.startHoverTimer()
            case .modifiersHeld, .activationTimedOut:
                // Stay armed: let the tech move away and come back to try again.
                self.sawPointerElsewhere = false
                self.dwellTicks = 0
                self.startHoverTimer()
            }
        }
    }
}
