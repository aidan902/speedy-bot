import AppKit

/// Where a screenshot turned up.
enum ScreenshotRef: Equatable {
    /// On the clipboard, at this change count.
    case clipboard(changeCount: Int)
    /// Saved by the system as a file (the tech's normal screenshot behaviour).
    case file(URL)
}

/// Where to look for screenshots.
enum ScreenshotSource: Equatable {
    case clipboard
    case folder(URL)
}

/// What makes a waiting screenshot go into ChatGPT.
enum PasteTrigger: String, CaseIterable, Identifiable {
    /// The pointer comes to rest on the ChatGPT window. No click, no key.
    case hover
    /// A double-click, or a triple-click, anywhere in the ChatGPT window.
    case doubleClick, tripleClick
    /// A keyboard shortcut the tech chose (also what a mouse button mapped to a keystroke sends).
    case shortcut

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: return "Pointer rests on ChatGPT"
        case .doubleClick: return "Double-click in ChatGPT"
        case .tripleClick: return "Triple-click in ChatGPT"
        case .shortcut: return "Keyboard shortcut"
        }
    }
}

/// Feature A: a fresh screenshot is pasted into ChatGPT, once per screenshot, when the tech's chosen trigger
/// happens: the pointer coming back to rest on the ChatGPT window (the default), a double- or triple-click
/// in it, or a keyboard shortcut.
///
///   a screenshot arrives (on the clipboard, or as a saved file) -> ARMED
///   the trigger happens -> bring ChatGPT forward, Cmd+V
///   anything else copied, or three minutes pass -> disarmed, nothing is pasted
///
/// The same watchers also feed "save screenshots for documentation" through `onScreenshot`.
@MainActor
final class ScreenshotPasteController {
    private struct Armed { let id: Int; let ref: ScreenshotRef; let at: Date }

    private unowned let state: AppState
    private lazy var clipboardWatcher = PasteboardWatcher { [weak self] count, isScreenshot in
        self?.clipboardChanged(count, isScreenshot: isScreenshot)
    }
    private lazy var folderWatcher = ScreenshotFolderWatcher { [weak self] url in self?.fileArrived(url) }
    private var pointerTimer: Timer?
    private var hoverTimer: Timer?
    private var armed: Armed?
    private var nextID = 1
    private var sawPointerElsewhere = false
    private var lastSeenOffChatGPT = Date.distantPast
    private var lastPointer = CGPoint.zero
    private var dwellTicks = 0
    private var loggedOccluder = false
    private var pasting = false
    private(set) var source: ScreenshotSource?
    /// Pasting itself. The watchers also run for saving screenshots, so this can be off while running.
    var pasteEnabled = true { didSet { if !pasteEnabled { disarm("paste switched off") }; syncTriggers() } }
    var trigger = PasteTrigger.hover { didSet { syncTriggers() } }
    /// The key combination for `PasteTrigger.shortcut`.
    var shortcut: HotKeySpec? { didSet { if shortcut != oldValue { hotKey?.unregister(); hotKey = nil; syncTriggers() } } }
    /// In the pointer-rest mode: a screenshot that has been waiting longer than this does not paste by itself any
    /// more; it needs a double-click in ChatGPT. nil = resting the pointer always pastes (for three minutes).
    var hoverMaxAge: TimeInterval? { didSet { syncTriggers() } }
    private var clickMonitor: Any?
    private var hotKey: GlobalHotKey?
    /// A click trigger that came before the screenshot's file was saved (the corner preview holds it back).
    private var earlyClick: Date?
    /// Called for every screenshot that arrives, before it is armed for pasting.
    var onScreenshot: ((ScreenshotRef) -> Void)?

    /// A screenshot older than this is never pasted. With the double-click rule on, an old screenshot cannot
    /// paste by accident, so it is kept ready for much longer.
    private var expiry: TimeInterval { hoverMaxAge == nil ? 180 : 1800 }
    private let tick: TimeInterval = 0.1
    /// The pointer has to REST on ChatGPT: this many ticks in a row, moving less than `restRadius` each tick.
    /// Crossing the window on the way to something else does not count.
    private let dwellNeeded = 3
    private let restRadius: CGFloat = 16

    init(state: AppState) { self.state = state }

    /// Starts (or switches to) a source. False when a screenshot folder cannot be watched.
    @discardableResult
    func start(source wanted: ScreenshotSource) -> Bool {
        if source == wanted { return true }
        stop()
        switch wanted {
        case .clipboard:
            clipboardWatcher.start()
        case .folder(let url):
            guard folderWatcher.start(folder: url) else { return false }
        }
        source = wanted
        // Remember where the pointer has been BEFORE a screenshot arrives, so a quick flick from the capture
        // straight onto ChatGPT still counts as "moved back to chat".
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
        syncTriggers()
        return true
    }

    func stop() {
        guard source != nil else { return }
        source = nil
        clipboardWatcher.stop()
        folderWatcher.stop()
        pointerTimer?.invalidate(); pointerTimer = nil
        disarm("stopped")
        syncTriggers()
    }

    // MARK: triggers

    /// Clicks are only listened for, and the shortcut only claimed, while they can mean something: the click
    /// listener while pasting is on with a click trigger, the shortcut only while a screenshot is waiting (so the
    /// key combination keeps its normal meaning the rest of the time).
    private func syncTriggers() {
        let wantClicks = source != nil && pasteEnabled
            && (trigger == .doubleClick || trigger == .tripleClick || (trigger == .hover && hoverMaxAge != nil))
        if wantClicks, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                let count = event.clickCount
                MainActor.assumeIsolated { self?.clicked(count: count) }
            }
        } else if !wantClicks, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
            earlyClick = nil
        }

        let wantKey = armed != nil && pasteEnabled && trigger == .shortcut && shortcut != nil
        if wantKey {
            if hotKey == nil, let shortcut {
                hotKey = GlobalHotKey(keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers) { [weak self] in self?.shortcutPressed() }
            }
            hotKey?.register()
        } else {
            hotKey?.unregister()
        }
    }

    private func clicked(count: Int) {
        guard count == (trigger == .tripleClick ? 3 : 2), pasteEnabled, !pasting, let target = chatGPTUnderPointer() else { return }
        if let armed {
            paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true)
        } else if case .folder = source, ScreencapturePrefs.thumbnailOn {
            earlyClick = Date()   // the screenshot may have been taken already and simply not be saved yet
        }
    }

    private func shortcutPressed() {
        guard let armed, !pasting else { return }
        if let target = chatGPTUnderPointer() {
            paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: Self.isChatGPT),
                  let window = WindowHitTest.frontWindow(ofPID: app.processIdentifier) {
            paste(into: app, window: window, armed: armed, pointerMustStay: false)
        } else {
            Toast.show("Open a ChatGPT window first", seconds: 2.5)
        }
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
        let ref = ScreenshotRef.clipboard(changeCount: count)
        onScreenshot?(ref)
        // The picture is on the clipboard within a second of the capture.
        arm(ref, pointerMemory: 1.2)
    }

    private func fileArrived(_ url: URL) {
        let ref = ScreenshotRef.file(url)
        onScreenshot?(ref)
        // A capture of two displays saves two files a moment apart; the first one (the main display) stays armed.
        if let armed, case .file = armed.ref, Date().timeIntervalSince(armed.at) < 1.5 { return }
        // With the corner preview on, the file is only saved about five seconds after the capture, and by then
        // the tech may already be resting on ChatGPT. Look further back for "the pointer was somewhere else".
        arm(ref, pointerMemory: ScreencapturePrefs.thumbnailOn ? 8 : 1.5)
        // The tech already double- or triple-clicked in ChatGPT while the corner preview was holding the file back.
        if let early = earlyClick, Date().timeIntervalSince(early) < 8, let armed, !pasting, let target = chatGPTUnderPointer() {
            paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true)
        }
        earlyClick = nil
    }

    private func arm(_ ref: ScreenshotRef, pointerMemory: TimeInterval) {
        guard pasteEnabled else { return }
        armed = Armed(id: nextID, ref: ref, at: Date())
        nextID += 1
        sawPointerElsewhere = Date().timeIntervalSince(lastSeenOffChatGPT) < pointerMemory
        dwellTicks = 0
        loggedOccluder = false
        state.armed = true
        let kind: String
        if case .file = ref { kind = "saved file" } else { kind = "clipboard" }
        SpeedyShared.log.notice("screenshot arrived (\(kind, privacy: .public)); trigger=\(self.trigger.rawValue, privacy: .public); pointer was elsewhere=\(self.sawPointerElsewhere)")
        startHoverTimer()
        syncTriggers()
    }

    private func disarm(_ why: String) {
        hoverTimer?.invalidate(); hoverTimer = nil
        guard armed != nil else { return }
        armed = nil
        state.armed = false
        SpeedyShared.log.notice("disarmed: \(why, privacy: .public)")
        syncTriggers()
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

    private func stillValid(_ armed: Armed) -> Bool {
        switch armed.ref {
        case .clipboard(let count): return NSPasteboard.general.changeCount == count
        case .file(let url): return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func hoverTick() {
        guard let armed, !pasting else { return }
        if Date().timeIntervalSince(armed.at) > expiry { disarm("expired"); return }
        if !stillValid(armed) { disarm("screenshot no longer there"); return }
        guard trigger == .hover else { return }   // the other triggers paste from a click or a key, not from here
        if let hoverMaxAge, Date().timeIntervalSince(armed.at) > hoverMaxAge { return }   // too old: double-click only

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
        paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true)
    }

    // MARK: paste

    private func paste(into app: NSRunningApplication, window: WindowUnderPointer, armed: Armed, pointerMustStay: Bool) {
        pasting = true
        hoverTimer?.invalidate(); hoverTimer = nil
        Task { @MainActor in
            // A saved file has to be put on the clipboard for the paste. What the tech had copied is kept and
            // put back afterwards, because in this mode a screenshot is not supposed to touch the clipboard.
            let expected: Int
            var borrowed: ClipboardSnapshot?
            var borrowedClipboard = false
            switch armed.ref {
            case .clipboard(let count):
                expected = count
            case .file(let url):
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    self.pasting = false
                    if self.armed?.id == armed.id { self.disarm("screenshot file could not be read") }
                    return
                }
                borrowed = ClipboardSwap.snapshot()
                expected = ClipboardSwap.putImage(data, fileExtension: url.pathExtension)
                borrowedClipboard = true
            }

            // Only the current ChatGPT app is known to route a paste to its message box from anywhere in the
            // window; its search and rename fields are the places a picture must not go.
            let result = await Paster.paste(
                into: app, window: window, expectedChangeCount: expected,
                refuseOtherTextFields: app.bundleIdentifier == "com.openai.codex",
                stillOnTarget: { !pointerMustStay || WindowHitTest.windowUnder()?.windowID == window.windowID })
            self.pasting = false
            SpeedyShared.log.notice("paste result: \(String(describing: result), privacy: .public)")

            if borrowedClipboard, let borrowed {
                // Give ChatGPT a moment to read the picture before the old contents go back; straight away
                // when nothing was pasted. Never overwrite something the tech copied in the meantime.
                let delay: Duration = result == .pasted ? .milliseconds(1200) : .zero
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    if NSPasteboard.general.changeCount == expected { ClipboardSwap.restore(borrowed) }
                }
            }

            // A newer screenshot arrived while this one was being pasted: it is the one that is armed now.
            guard self.armed?.id == armed.id else {
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
                Toast.show(borrowedClipboard ? "Click the ChatGPT message box, then take the screenshot again"
                                             : "Screenshot is on the clipboard. Click the message box and press ⌘V", seconds: 3.5)
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
