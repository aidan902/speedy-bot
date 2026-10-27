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

/// The chat apps a screenshot can be pasted into.
enum PasteTarget: String, CaseIterable, Identifiable {
    case chatGPT, claude, grok

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }

    /// Only ChatGPT is known to route a paste made anywhere in its window to the message box; there its search and
    /// rename fields are the places a picture must not go. The others get a plain Cmd+V wherever the cursor is.
    var refusesOtherTextFields: Bool { self == .chatGPT }

    func matches(_ app: NSRunningApplication) -> Bool {
        let bid = app.bundleIdentifier ?? ""
        switch self {
        case .chatGPT:
            // The current app and Codex.app share the bundle id com.openai.codex, so the name is checked as well;
            // helper processes ("ChatGPT Computer Use", "ChatGPTHelper") have other bundle ids.
            if bid == "com.openai.chat" { return true }
            return bid == "com.openai.codex" && (app.bundleURL?.deletingPathExtension().lastPathComponent == "ChatGPT" || app.localizedName == "ChatGPT")
        case .claude:
            return bid == "com.anthropic.claudefordesktop"
        case .grok:
            return ["ai.x.grok", "com.x.grok", "com.xai.grok"].contains(bid) || (bid.lowercased().contains("grok") && app.localizedName == "Grok")
        }
    }

    static func matching(_ app: NSRunningApplication, in targets: Set<PasteTarget>) -> PasteTarget? {
        targets.first { $0.matches(app) }
    }

    /// "ChatGPT", "ChatGPT or Claude", "ChatGPT, Claude or Grok".
    static func names(_ targets: Set<PasteTarget>) -> String {
        let list = allCases.filter(targets.contains).map(\.title)
        guard list.count > 1 else { return list.first ?? "ChatGPT" }
        return list.dropLast().joined(separator: ", ") + " or " + list.last!
    }
}

/// What makes a waiting screenshot go into ChatGPT.
enum PasteTrigger: String, CaseIterable, Identifiable {
    /// The pointer moves onto the ChatGPT window. No click, no key, no waiting.
    case hover
    /// A double-click, or a triple-click, anywhere in the ChatGPT window.
    case doubleClick, tripleClick
    /// A keyboard shortcut the tech chose (also what a mouse button mapped to a keystroke sends).
    case shortcut

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: return "Pointer moves onto MCP(s)"
        case .doubleClick: return "Double-click in MCP(s)"
        case .tripleClick: return "Triple-click in MCP(s)"
        case .shortcut: return "Keyboard shortcut"
        }
    }
}

/// Feature A: a fresh screenshot is pasted into ChatGPT, once per screenshot, when the tech's chosen trigger
/// happens: the pointer coming back onto the ChatGPT window (the default), a double- or triple-click in it,
/// or a keyboard shortcut.
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
    private var dwellTicks = 0
    private var loggedOccluder = false
    private var pasting = false
    private(set) var source: ScreenshotSource?
    /// Pasting itself. The watchers also run for saving screenshots, so this can be off while running.
    var pasteEnabled = true {
        didSet {
            if !pasteEnabled {
                disarm("paste switched off")
                pendingSends.removeAll()   // nothing waiting to send may still go
                releaseIfIdle()
            }
            syncTriggers()
        }
    }
    var trigger = PasteTrigger.hover { didSet { syncTriggers() } }
    /// Which chat apps count. Always at least one.
    var targets: Set<PasteTarget> = [.chatGPT] { didSet { if targets != oldValue { releaseIfIdle(); primeChatApps() } } }
    /// The key combination for `PasteTrigger.shortcut`.
    var shortcut: HotKeySpec? { didSet { if shortcut != oldValue { hotKey?.unregister(); hotKey = nil; syncTriggers() } } }
    /// In the pointer-rest mode: a screenshot that has been waiting longer than this does not paste by itself any
    /// more; it needs a double-click in ChatGPT. nil = resting the pointer always pastes (for three minutes).
    var hoverMaxAge: TimeInterval? { didSet { syncTriggers() } }
    private var clickMonitor: Any?
    private var hotKey: GlobalHotKey?
    /// The system's corner preview is showing: a screenshot has been taken whose file is not saved yet.
    private var capturePending = false
    /// A click or shortcut trigger that came while that file was still on its way.
    private var earlyTrigger: (at: Date, byShortcut: Bool)?
    /// What the tech had on the clipboard before a saved screenshot was put there for pasting.
    private var borrow: (snapshot: ClipboardSnapshot, count: Int, token: Int)?
    private var nextBorrowToken = 1
    /// A screenshot taken while working in a ScreenConnect session goes into the chat and is SENT, with no
    /// pointer move, as long as a chat window is open on the same desktop.
    var autoSendFromSession = false {
        didSet {
            if autoSendFromSession, !oldValue { primeChatApps() }
            if !autoSendFromSession, oldValue {
                // Switched off: nothing waiting to send may still go.
                pendingSends.removeAll()
                deferredAutoSend = nil
                releaseChatApps()
            }
        }
    }
    /// The auto-send waiting to press Send in each chat window (by window), and how many pictures the box held
    /// right after its paste. A newer paste into the window replaces it.
    private var pendingSends: [CGWindowID: (token: Int, images: Int, extras: Int)] = [:]
    /// How many unnamed buttons each chat window's composer shows of its own, seen when its box was empty and idle:
    /// while an answer runs, only buttons beyond these mean pictures or files in the box.
    private var idleExtras: [CGWindowID: Int] = [:]
    /// Which paste holds `pasting`: only that paste may clear it (a waiting send finishing later must not).
    private var pasteGeneration = 0
    private var nextSendToken = 1
    /// A session screenshot that arrived while another paste was under way: pasted once that paste is done, if it
    /// is still the screenshot waiting.
    private var deferredAutoSend: (armedID: Int, returnTo: NSRunningApplication?, multi: Bool, at: Date)?
    /// A paste the keypad asked for while no screenshot was waiting (or one was still being saved): the screenshot
    /// that arrives next, within `within` seconds, goes into the chat app this way (sent or not) instead of the
    /// usual rules. `ownCapture`: only the session-window capture the key started counts (a capture that never
    /// started must not hand its key's meaning to some other screenshot).
    private var keyIntent: (send: Bool, at: Date, within: TimeInterval, ownCapture: Bool)?
    /// The keypad pastes a waiting screenshot only while it is this fresh; an older one is replaced by a new
    /// capture of the session window (when there is a session to capture).
    private let keyFreshness: TimeInterval = 60
    /// While an auto-paste of ours has the chat app in front (and just after), a screenshot still counts as taken
    /// in the session it came from.
    private var recentAutoPaste: (session: NSRunningApplication, chatPID: pid_t, until: Date)?
    private var launchObserver: NSObjectProtocol?
    /// The last moment a ScreenConnect session was the app in front (or its window was captured with the shortcut).
    private var sessionInFrontAt = Date.distantPast
    /// Multi-capture: every window capture (the ⇧⌘2 shortcut) goes straight into the MCP's message box, NOT sent,
    /// and focus comes back to the session, so several captures can be gathered into one message.
    var multiCapture = false
    private var sessionCaptureAt = Date.distantPast
    /// When the latest screenshot arrived: the keys and drag that took it are not the tech working in the chat app.
    private var lastScreenshotAt = Date.distantPast
    /// Called for every screenshot that arrives, before it is armed for pasting.
    var onScreenshot: ((ScreenshotRef) -> Void)?

    /// A screenshot older than this is never pasted. With the double-click rule on, an old screenshot cannot
    /// paste by accident, so it is kept ready for much longer.
    private var expiry: TimeInterval { hoverMaxAge == nil ? 180 : 1800 }
    private let tick: TimeInterval = 0.07
    /// The paste fires as soon as the pointer is seen on ChatGPT (one tick), the moment it arrives.
    private let dwellNeeded = 1

    init(state: AppState) { self.state = state }

    /// Starts (or switches to) a source. False when a screenshot folder cannot be watched.
    @discardableResult
    func start(source wanted: ScreenshotSource) -> Bool {
        if source == wanted, isHealthy { return true }
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
        primeChatApps()
        if launchObserver == nil {
            // ChatGPT opened (or reopened by its own update) after Speedy Bot: wake it once it is up.
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, PasteTarget.chatGPT.matches(app) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self?.primeChatApps() } }
            }
        }
        return true
    }

    func stop() {
        guard source != nil else { return }
        source = nil
        clipboardWatcher.stop()
        folderWatcher.stop()
        pointerTimer?.invalidate(); pointerTimer = nil
        capturePending = false
        earlyTrigger = nil
        disarm("stopped")
        returnBorrowedClipboard()
        syncTriggers()
        deferredAutoSend = nil
        // A send already waiting (the last screenshot of a session, an answer still coming) finishes on its own;
        // ChatGPT's flag goes off once nothing is waiting any more.
        releaseIfIdle()
    }

    /// Speedy Bot switched Off: nothing waiting may still be sent.
    func cancelPendingSends() {
        guard !pendingSends.isEmpty || deferredAutoSend != nil else { return }
        SpeedyShared.log.notice("auto-send: \(self.pendingSends.count) waiting send(s) cancelled (Speedy Bot off)")
        pendingSends.removeAll()
        deferredAutoSend = nil
        releaseIfIdle()
    }

    /// False when the watched screenshot folder has gone away (renamed, deleted, unmounted) and must be found again.
    var isHealthy: Bool {
        if case .folder = source { return folderWatcher.isAlive }
        return source != nil
    }

    /// Whether the corner preview holds new screenshot files back (only relevant when watching a folder).
    private var previewDelaysFiles: Bool {
        if case .folder = source { return ScreencapturePrefs.thumbnailOn }
        return false
    }

    /// The one-press capture of the session window is, by definition, a screenshot taken from the session.
    func noteSessionCapture() { sessionInFrontAt = Date(); sessionCaptureAt = Date() }

    private func samplePointer() {
        if autoSendFromSession, let front = NSWorkspace.shared.frontmostApplication, FrontmostAppGate.isScreenConnect(front) {
            sessionInFrontAt = Date()
        }
        if previewDelaysFiles {
            let pending = WindowHitTest.screenshotPreviewVisible()
            if pending != capturePending { capturePending = pending; syncTriggers() }
        }
        guard pasteEnabled, armed == nil else { return }   // while armed the hover timer keeps this up to date
        if targetUnderPointer() == nil { lastSeenOffChatGPT = Date() }
    }

    // MARK: triggers

    /// Clicks are only listened for, and the shortcut only claimed, while they can mean something: the click
    /// listener while pasting is on with a click trigger, the shortcut only while a screenshot is waiting or on
    /// its way (so the key combination keeps its normal meaning the rest of the time).
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
        }

        let wantKey = (armed != nil || capturePending) && pasteEnabled && trigger == .shortcut && shortcut != nil
        if wantKey {
            if hotKey == nil, let shortcut {
                hotKey = GlobalHotKey(keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers) { [weak self] in self?.shortcutPressed() }
            }
            if hotKey?.register() != noErr {
                SpeedyShared.log.error("the paste shortcut could not be registered (already taken?)")
            }
        } else {
            hotKey?.unregister()
        }
    }

    /// A screenshot has been taken whose file is not there yet: a trigger now is meant for THAT screenshot,
    /// not for an older one that happens to be still waiting.
    private func noteEarlyTrigger(byShortcut: Bool) -> Bool {
        guard previewDelaysFiles, capturePending || armed == nil else { return false }
        earlyTrigger = (Date(), byShortcut)
        return true
    }

    private func clicked(count: Int) {
        guard count == (trigger == .tripleClick ? 3 : 2), pasteEnabled, !pasting else { return }
        let point = WindowHitTest.pointer()
        guard let target = targetUnderPointer(point), !isCovered(point, target.app, window: target.window.windowID) else { return }
        if noteEarlyTrigger(byShortcut: false) { return }
        if let armed { paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true) }
    }

    private func shortcutPressed() {
        guard !pasting else { return }
        if noteEarlyTrigger(byShortcut: true) { return }
        guard let armed else { return }
        guard let target = shortcutTarget() else {
            Toast.show("Open a \(PasteTarget.names(targets)) window first", seconds: 2.5)
            return
        }
        paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false)
    }

    /// The chat window under the pointer, else the frontmost window of whichever chosen chat app is open.
    private func shortcutTarget() -> (app: NSRunningApplication, window: WindowUnderPointer)? {
        if let target = targetUnderPointer() { return target }
        let apps = NSWorkspace.shared.runningApplications.filter { PasteTarget.matching($0, in: targets) != nil }
        // The one in front first, if one of them is.
        let ordered = apps.sorted { a, _ in a.isActive }
        for app in ordered {
            if let window = WindowHitTest.frontWindow(ofPID: app.processIdentifier) { return (app, window) }
        }
        return nil
    }

    /// The window list only knows ordinary windows. A menu, popover or floating panel over ChatGPT belongs to
    /// someone else, and accessibility can see that.
    private func isCovered(_ point: CGPoint, _ app: NSRunningApplication, window: CGWindowID) -> Bool {
        // Usually nothing is drawn over the window, and the window list says so at no cost. Only when something
        // is there does accessibility get asked what it is (that question can take a moment with a web-based app).
        guard WindowHitTest.somethingElseAbove(point, window: window, ownerPID: app.processIdentifier) else { return false }
        guard let owner = Paster.ownerPID(at: point), owner != app.processIdentifier else { return false }
        if !loggedOccluder {
            loggedOccluder = true
            SpeedyShared.log.notice("pointer is over ChatGPT but process \(owner) has something on top of it; not pasting there")
        }
        return true
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
        sendIfTakenInSession(within: 1.5)
    }

    /// The keypad's Paste / Paste-and-send keys: the waiting screenshot goes into the chat app (and, for Paste and
    /// send, is sent the safe auto-send way, whether or not auto-send is switched on). A screenshot the corner
    /// preview is still holding back is the one the key means; with none waiting, or only one older than a minute,
    /// the session window is captured first (`capture`, when `canCapture`).
    func pasteFromKey(send: Bool, canCapture: Bool, capture: () -> Void) {
        guard pasteEnabled, source != nil else { Toast.show("Pasting screenshots is switched off in Speedy Bot", seconds: 2.5); return }
        guard !pasting else { Toast.show("A paste is already under way", seconds: 1.5); return }
        // Reading the message box needs ChatGPT's tree, which is only kept up ahead of time while auto-send is on.
        if send, targets.contains(.chatGPT) {
            for app in NSWorkspace.shared.runningApplications where PasteTarget.chatGPT.matches(app) {
                ChatSend.wakeAccessibility(pid: app.processIdentifier)
            }
        }
        if previewDelaysFiles, capturePending {
            // Its file lands once the preview is gone (about 5 s, longer while the pointer rests on it).
            keyIntent = (send, Date(), 20, false)
            SpeedyShared.log.notice("keypad: waiting for the screenshot still being saved")
            return
        }
        if let armed, stillValid(armed), !canCapture || Date().timeIntervalSince(armed.at) < keyFreshness {
            keyIntent = nil
            runKeyPaste(send: send, armed: armed, pressedAt: Date())
        } else if canCapture {
            keyIntent = (send, Date(), 8, true)
            capture()
        } else {
            Toast.show("No screenshot waiting to paste", seconds: 2)
        }
    }

    private func runKeyPaste(send: Bool, armed: Armed, pressedAt: Date) {
        guard let target = shortcutTarget() else {
            Toast.show("Open \(PasteTarget.names(targets)) first", seconds: 2.5)
            return
        }
        let session = NSWorkspace.shared.frontmostApplication.flatMap { FrontmostAppGate.isScreenConnect($0) ? $0 : nil }
        SpeedyShared.log.notice("keypad: pasting \(send ? "and sending" : "without sending", privacy: .public)")
        paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false, thenSend: send, returnTo: session,
              keyPressedAt: pressedAt)
    }

    /// The screenshot that has just been armed was taken while the tech was in a ScreenConnect session, and a
    /// chat window is open on this desktop: paste it there and send it, without waiting for any trigger.
    private func sendIfTakenInSession(within memory: TimeInterval) {
        guard let armed else { return }
        // The keypad asked for this screenshot: it goes the way the key said.
        if let intent = keyIntent {
            keyIntent = nil
            if Date().timeIntervalSince(intent.at) < intent.within, !intent.ownCapture || sessionCaptureAt >= intent.at, !pasting {
                runKeyPaste(send: intent.send, armed: armed, pressedAt: intent.at)
                return
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        var session = front.flatMap { FrontmostAppGate.isScreenConnect($0) ? $0 : nil }
        // An auto-paste of ours has the chat app in front for a moment: the tech is still in their session.
        var viaOurPaste = false
        if session == nil, let recent = recentAutoPaste, Date() < recent.until, !recent.session.isTerminated,
           front?.processIdentifier == recent.chatPID {
            session = recent.session
            viaOurPaste = true
        }
        let windowCapture = Date().timeIntervalSince(sessionCaptureAt) < 4
        let multi = multiCapture && windowCapture
        // Only a screenshot from a session that is still in front, or the session-window capture: a file that lands
        // seconds later, after the tech has moved on to another app, must not pull the chat app over it.
        let auto = autoSendFromSession && (viaOurPaste || Date().timeIntervalSince(sessionInFrontAt) < memory) && (session != nil || windowCapture)
        guard multi || auto else { return }
        if pasting {
            // Another paste is under way; this one goes once that is done (if it is still the one waiting).
            deferredAutoSend = (armed.id, session, multi, Date())
            return
        }
        runSessionPaste(returnTo: session, multi: multi)
    }

    private func runSessionPaste(returnTo session: NSRunningApplication?, multi: Bool) {
        guard let armed, let target = shortcutTarget() else { return }
        if multi {
            // A window capture with multi-capture on: into the message box, not sent, and back to the session.
            SpeedyShared.log.notice("window capture; pasting without sending (multi-capture)")
            paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false, returnTo: session)
        } else {
            SpeedyShared.log.notice("screenshot was taken in a ScreenConnect session; pasting and sending")
            paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false, thenSend: true, returnTo: session)
        }
    }

    private func fileArrived(_ url: URL) {
        let ref = ScreenshotRef.file(url)
        onScreenshot?(ref)
        // A capture of two displays saves two files a moment apart; the first one (the main display) stays armed.
        if let armed, case .file = armed.ref, Date().timeIntervalSince(armed.at) < 1.5 { return }
        // With the corner preview on, the file is only saved about five seconds after the capture, and by then
        // the tech may already be resting on ChatGPT. Look further back for "the pointer was somewhere else".
        arm(ref, pointerMemory: ScreencapturePrefs.thumbnailOn ? 8 : 1.5)
        sendIfTakenInSession(within: ScreencapturePrefs.thumbnailOn ? 9 : 2)
        if pasting { earlyTrigger = nil; return }

        // The tech already clicked or pressed the shortcut while the corner preview was holding this file back.
        let early = earlyTrigger
        earlyTrigger = nil
        guard let early, Date().timeIntervalSince(early.at) < 10, let armed, !pasting else { return }
        if early.byShortcut {
            if let target = shortcutTarget() { paste(into: target.app, window: target.window, armed: armed, pointerMustStay: false) }
        } else {
            let point = WindowHitTest.pointer()
            if let target = targetUnderPointer(point), !isCovered(point, target.app, window: target.window.windowID) {
                paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true)
            }
        }
    }

    private func arm(_ ref: ScreenshotRef, pointerMemory: TimeInterval) {
        guard pasteEnabled else { return }
        lastScreenshotAt = Date()
        armed = Armed(id: nextID, ref: ref, at: Date())
        nextID += 1
        sawPointerElsewhere = Date().timeIntervalSince(lastSeenOffChatGPT) < pointerMemory
        dwellTicks = 0
        loggedOccluder = false
        state.armed = true
        let kind: String
        if case .file = ref { kind = "saved file" } else { kind = "clipboard" }
        SpeedyShared.log.notice("screenshot arrived (\(kind, privacy: .public)); trigger=\(self.trigger.rawValue, privacy: .public); pointer was elsewhere=\(self.sawPointerElsewhere)")
        primeChatApps()
        startHoverTimer()
        syncTriggers()
    }

    private func disarm(_ why: String) {
        hoverTimer?.invalidate(); hoverTimer = nil
        deferredAutoSend = nil
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

    /// The window under the pointer, if it belongs to one of the chosen chat apps.
    private func targetUnderPointer(_ point: CGPoint = WindowHitTest.pointer()) -> (app: NSRunningApplication, window: WindowUnderPointer)? {
        guard let w = WindowHitTest.windowUnder(point), w.bounds.width >= 200, w.bounds.height >= 120,
              let app = NSRunningApplication(processIdentifier: w.ownerPID), PasteTarget.matching(app, in: targets) != nil else { return nil }
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

        // Keep track of where the pointer has been whatever the trigger is: the next screenshot needs to know.
        let point = WindowHitTest.pointer()
        guard let target = targetUnderPointer(point) else {
            sawPointerElsewhere = true
            lastSeenOffChatGPT = Date()
            dwellTicks = 0
            return
        }

        guard trigger == .hover else { return }   // the other triggers paste from a click or a key, not from here
        if let hoverMaxAge, Date().timeIntervalSince(armed.at) > hoverMaxAge { return }   // too old: double-click only
        // "Moves back to chat": the pointer must have been somewhere else since the screenshot was taken.
        guard sawPointerElsewhere else { return }
        // Dragging something across the window is not "coming back to chat".
        if CGEventSource.buttonState(.hidSystemState, button: .left) || CGEventSource.buttonState(.hidSystemState, button: .right) {
            dwellTicks = 0
            return
        }
        dwellTicks += 1
        guard dwellTicks >= dwellNeeded else { return }
        if isCovered(point, target.app, window: target.window.windowID) {
            dwellTicks = 0
            return
        }
        SpeedyShared.log.notice("pointer moved onto \(PasteTarget.matching(target.app, in: self.targets)?.title ?? "the chat app", privacy: .public); pasting")
        paste(into: target.app, window: target.window, armed: armed, pointerMustStay: true)
    }

    // MARK: paste

    /// Puts back what the tech had copied before a saved screenshot was put on the clipboard for pasting, unless
    /// they have copied something else since.
    private func returnBorrowedClipboard(token: Int? = nil) {
        guard let borrow, token == nil || token == borrow.token else { return }
        self.borrow = nil
        if NSPasteboard.general.changeCount == borrow.count { ClipboardSwap.restore(borrow.snapshot) }
    }

    /// Sends what was pasted, as soon as it is safe, by pressing the app's own Send button (which works with the
    /// app in the background). It stands down, leaving everything in the box for the tech, as soon as anything
    /// suggests the message is no longer just the screenshot: text in the box, more pictures than were pasted, the
    /// box replaced (another conversation), the tech working in the chat app, a newer paste into the window, or
    /// auto-send switched off. Counted as sent only when an answer starts or the Send button goes away (an empty
    /// box). Never presses Return. Returns whether it was sent.
    /// `returnTo`: the session the tech was handed back to (`handedBack`), or would have been. `byKey`: the keypad's
    /// Paste and send asked for this one, so it goes whether or not auto-send is switched on.
    private func send(in app: NSRunningApplication, window: CGWindowID, composer: Composer, baselineImages: Int,
                      baselineExtras: Int, relocations: Int, handoff: Date, handedBack: Bool, returnTo: NSRunningApplication?,
                      token: Int, byKey: Bool) async -> Bool {
        let name = PasteTarget.matching(app, in: targets)?.title ?? "the chat"
        let pid = app.processIdentifier
        let started = ContinuousClock.now
        func elapsed() -> Double { Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000 }
        func ms() -> Int { Int(elapsed() * 1000) }
        func stillOurs() -> Bool { pendingSends[window]?.token == token && (autoSendFromSession || byKey) && pasteEnabled }
        func finish(_ sent: Bool, _ why: String, toast: String?) -> Bool {
            if pendingSends[window]?.token == token { pendingSends[window] = nil }
            SpeedyShared.log.notice("auto-send: \(why, privacy: .public) at \(ms()) ms")
            if let toast { Toast.show(toast, seconds: sent ? 1.4 : 4) }
            releaseIfIdle()
            return sent
        }
        let notSent = "Screenshot pasted into \(name), not sent. Send it from \(name)"
        let leftForTech = "Screenshot left in \(name), not sent"
        var imagesBase = baselineImages, extrasBase = baselineExtras
        // The tech is in the chat app doing something: after being handed back to the session, coming back to
        // the chat app at all (another conversation, another window, a file) makes it theirs; otherwise any key,
        // click or drag in the chat app does. "Coming back" needs the chat app to have been seen behind the session
        // first: the hand-back takes a moment, and right after it the chat app still reads as the one in front. It
        // does not count when the session itself has gone (macOS then brings the next window forward, often the
        // chat app); then only input there does. A paste of ours under way (which brings the chat app forward)
        // does not count, and neither do the keys and drag that take the next screenshot: input before a screenshot
        // arrived was taking it, and the latest input only counts once 2 s have gone by with no screenshot on its
        // way (until then the send waits).
        enum ChatActivity { case none, maybe, working }
        var leftChat = false                // the chat app has been seen behind another app since the paste
        var chatInFront = true              // as last seen
        var chatInFrontSince = handoff      // since when the chat app has been in front this time
        func chatActivity() -> ChatActivity {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == pid else {
                if front != nil { leftChat = true; chatInFront = false }
                return .none
            }
            if !chatInFront { chatInFront = true; chatInFrontSince = Date() }
            guard !pasting else { return .none }
            if handedBack, leftChat, returnTo.map({ !$0.isTerminated }) ?? false { return .working }
            guard Self.input(since: max(chatInFrontSince, lastScreenshotAt)) else { return .none }
            return Self.secondsSinceInput() < 2 || capturePending ? .maybe : .working
        }
        var lastProgress = 0.0          // reset while an answer is in progress
        var unreadableSince: Double?
        var presses = 0
        while true {
            guard stillOurs() else {
                // Taken over by a newer paste into this window, or cancelled (switched off, a paste by hand).
                let takenOver = pendingSends[window].map { $0.token != token } ?? false
                return finish(false, takenOver ? "stood down: a newer paste into this window" : "stood down: cancelled",
                              toast: !takenOver && byKey ? notSent : nil)
            }
            let activity = chatActivity()
            if activity == .working { return finish(false, "the tech is working in the chat app; left for them", toast: leftForTech) }
            if activity == .maybe || pasting {
                // Maybe the next screenshot on its way, or a paste of ours under way that may join this send.
                if elapsed() > 120 { return finish(false, "still busy after 120 s; not sent", toast: notSent) }
                lastProgress = elapsed()
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            let s = await Task.detached { composer.read() }.value
            guard let typed = s.typed else {
                // The box could not be read (the page re-drawing, the app busy): give it a moment before giving up.
                if unreadableSince == nil { unreadableSince = elapsed() }
                if elapsed() - (unreadableSince ?? 0) > 3 { return finish(false, "message box unreadable; not sent", toast: notSent) }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            unreadableSince = nil
            if !typed.isEmpty { return finish(false, "text in the box; left for the tech", toast: leftForTech) }
            if composer.relocations != relocations { return finish(false, "the message box was replaced (another chat?)", toast: notSent) }
            if elapsed() < 1.5 || (elapsed() < 4 && !s.streaming && s.sendButton != nil && s.sendEnabled == false) {
                // The picture may still be settling into the box (its chip appears and changes as it uploads, which
                // keeps Send greyed out): take that in, and let a screenshot that joins this send know.
                imagesBase = max(imagesBase, s.images)
                extrasBase = max(extrasBase, s.extras)
                if stillOurs() { pendingSends[window] = (token, imagesBase, extrasBase) }
            } else if s.images > imagesBase || s.extras > extrasBase {
                SpeedyShared.log.notice("auto-send: composer buttons = [\(s.buttons.joined(separator: ", "), privacy: .public)]")
                return finish(false, "more pictures or files in the box; left for the tech", toast: leftForTech)
            }
            if s.streaming {
                lastProgress = elapsed()
            } else if s.sendButton != nil, s.sendEnabled == true {
                // Last look right before pressing: nothing may have changed in between.
                let fresh = await Task.detached { composer.read() }.value
                if stillOurs(), !pasting, chatActivity() == .none, fresh.typed == "", !fresh.streaming, fresh.sendEnabled == true,
                   fresh.images <= imagesBase, fresh.extras <= extrasBase, composer.relocations == relocations, let button = fresh.sendButton {
                    presses += 1
                    let accepted = await Task.detached { ChatSend.press(SendButton(element: button)) }.value
                    if await confirmSent(composer, window: window, token: token) {
                        return finish(true, "sent (button)", toast: "Screenshot sent to \(name)")
                    }
                    if !stillOurs() { continue }
                    SpeedyShared.log.notice("auto-send: press \(presses) not confirmed (accepted=\(accepted))")
                    if presses >= 2 {
                        return finish(false, "Send pressed but not confirmed", toast: "Screenshot pasted into \(name); it may not have sent. Check \(name)")
                    }
                    continue
                }
            }
            // Waiting for the upload to finish (Send disabled) or for an answer to end (Stop showing).
            if elapsed() - lastProgress > 15 || elapsed() > 120 {
                SpeedyShared.log.notice("auto-send: composer buttons = [\(s.buttons.joined(separator: ", "), privacy: .public)]")
                return finish(false, "the Send button never became ready", toast: notSent)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// After a press: an answer starts, or the Send button goes away (it is only there while the box holds
    /// something), within a few seconds. Gives up at once when a newer paste has taken over.
    private func confirmSent(_ composer: Composer, window: CGWindowID, token: Int) async -> Bool {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            guard pendingSends[window]?.token == token else { return false }
            let s = await Task.detached { composer.read() }.value
            if s.streaming { return true }
            if s.typed == "", s.sendButton == nil { return true }
        }
        return false
    }

    /// No click, key press or scroll since then: the tech has not started doing something else.
    private static func techIdle(since: Date) -> Bool {
        !input(since: since) && CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel) >= Date().timeIntervalSince(since)
    }

    /// A key, click or drag (hardware) since then.
    private static func input(since: Date) -> Bool {
        let gone = Date().timeIntervalSince(since)
        guard gone > 0 else { return false }
        for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
            where CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) < gone {
            return true
        }
        return false
    }

    /// How long ago the latest key, click or drag (hardware) was.
    private static func secondsSinceInput() -> TimeInterval {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// Has ChatGPT build its accessibility tree ahead of time, so an auto-send can read its message box straight
    /// away. Never brings the app forward. Only ChatGPT needs (and gets) this, and only while auto-send is running.
    func primeChatApps() {
        guard autoSendFromSession, pasteEnabled, source != nil, targets.contains(.chatGPT) else { return }
        for app in NSWorkspace.shared.runningApplications where PasteTarget.chatGPT.matches(app) {
            ChatSend.wakeAccessibility(pid: app.processIdentifier)
        }
    }

    /// Auto-send is off or Speedy Bot is stopping: ChatGPT no longer needs its tree kept up for us.
    private func releaseChatApps() { ChatSend.releaseAccessibility() }

    /// ChatGPT's flag goes off once nothing is waiting to send and auto-send cannot run (stopped, paste off,
    /// auto-send off, or ChatGPT not among the chat apps).
    private func releaseIfIdle() {
        // A paste under way, or one the keypad has asked for, may still need to read the message box.
        let keyWaiting = keyIntent.map { Date().timeIntervalSince($0.at) < $0.within } ?? false
        guard pendingSends.isEmpty, !pasting, !keyWaiting else { return }
        if source == nil || !pasteEnabled || !autoSendFromSession || !targets.contains(.chatGPT) { releaseChatApps() }
    }

    /// The paste `generation` is finished (or abandoned): a session screenshot that came in meanwhile goes now,
    /// if the tech is still where it was taken and has not started something else since.
    private func donePasting(_ generation: Int) {
        guard generation == pasteGeneration, pasting else { return }
        pasting = false
        guard let deferred = deferredAutoSend else { releaseIfIdle(); return }
        deferredAutoSend = nil
        guard armed?.id == deferred.armedID, Date().timeIntervalSince(deferred.at) < 15 else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let stillThere = deferred.returnTo == nil || front == deferred.returnTo?.processIdentifier
            || (recentAutoPaste.map { Date() < $0.until && front == $0.chatPID } ?? false)
        if !stillThere || Self.input(since: deferred.at) {
            SpeedyShared.log.notice("auto-send: the tech moved on before the held-back screenshot's turn; left ready to paste")
            Toast.show("Screenshot ready. Move to \(PasteTarget.names(targets)) to paste it", seconds: 2.5)
            return
        }
        runSessionPaste(returnTo: deferred.returnTo, multi: deferred.multi)
    }

    private func paste(into app: NSRunningApplication, window: WindowUnderPointer, armed: Armed, pointerMustStay: Bool,
                       thenSend: Bool = false, returnTo: NSRunningApplication? = nil, keyPressedAt: Date? = nil) {
        pasteGeneration += 1
        let generation = pasteGeneration
        pasting = true
        hoverTimer?.invalidate(); hoverTimer = nil
        Task { @MainActor in
            // A saved file has to be put on the clipboard for the paste. What the tech had copied is kept and
            // put back afterwards, because in this mode a screenshot is not supposed to touch the clipboard.
            let expected: Int
            var borrowToken: Int?
            var clipboardReplaced = false
            switch armed.ref {
            case .clipboard(let count):
                expected = count
            case .file(let url):
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    if self.armed?.id == armed.id { self.disarm("screenshot file could not be read") }
                    self.donePasting(generation)
                    return
                }
                // If an earlier screenshot is still sitting on the clipboard from the paste before, what has to
                // come back in the end is what the tech had before THAT one, not the earlier screenshot.
                let original: ClipboardSnapshot?
                if let earlier = self.borrow, NSPasteboard.general.changeCount == earlier.count {
                    original = earlier.snapshot
                } else {
                    original = ClipboardSwap.snapshot()
                }
                expected = ClipboardSwap.putImage(data, fileExtension: url.pathExtension)
                if let original {
                    self.borrow = (original, expected, self.nextBorrowToken)
                    borrowToken = self.nextBorrowToken
                    self.nextBorrowToken += 1
                } else {
                    self.borrow = nil
                    clipboardReplaced = true   // too big to set aside, or macOS will not let it be read quietly
                    SpeedyShared.log.notice("the clipboard could not be set aside; it now holds the screenshot")
                }
            }
            let name = PasteTarget.matching(app, in: self.targets)?.title ?? "the chat"
            let windowID = window.windowID

            // Auto-send must never send anything the tech has put in the box, so the message box of this very window
            // is read first: any typed text, or pictures and files other than our own auto-send still waiting there,
            // mean paste only. A box that cannot be read within 3 s (the tree still waking) also means paste only.
            var sendPlan: Composer?
            var notSentWhy = ""
            if thenSend {
                let composer = Composer(pid: app.processIdentifier, windowID: windowID)
                let lookStarted = Date()
                let before = await Task.detached { () -> ComposerState in
                    let deadline = Date().addingTimeInterval(3)
                    var s = composer.read()
                    while s.text == nil, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(250))
                        s = composer.read()
                    }
                    return s
                }.value
                let ours = self.pendingSends[windowID]   // an earlier auto-send still waiting in this window
                if before.typed == "", !before.streaming, before.sendButton == nil, before.images == 0, ours == nil {
                    self.idleExtras[windowID] = before.extras   // an empty, idle box: these buttons are the composer's own
                }
                let ownExtras = self.idleExtras[windowID] ?? 0
                if before.typed == nil {
                    notSentWhy = "unreadable"
                } else if before.typed?.isEmpty == false {
                    notSentWhy = "draft"
                } else if let ours, before.images <= ours.images, before.extras <= ours.extras {
                    sendPlan = composer   // only our own pending screenshots are there: this one joins them
                } else if before.images > 0 || (!before.streaming && before.sendButton != nil) || (before.streaming && before.extras > ownExtras) {
                    // Pictures or files already in the box. A Send button means the box holds something; while an
                    // answer runs the Send button is hidden, so any composer button beyond its fixed ones counts.
                    notSentWhy = "draft"
                } else {
                    sendPlan = composer
                }
                SpeedyShared.log.notice("auto-send: before the paste: \(sendPlan != nil ? (ours != nil ? "joining the pending send" : "box clear") : notSentWhy, privacy: .public), streaming=\(before.streaming), pictures=\(before.images), extras=\(before.extras), composer=[\(before.buttons.joined(separator: ", "), privacy: .public)]")
                // A slow look (the tree was still waking): only pull the chat app forward if the tech is still where
                // the screenshot was taken (or the key pressed) and has not started anything else since.
                if Date().timeIntervalSince(lookStarted) > 0.6 {
                    let stillThere = returnTo.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier } ?? true
                    if !stillThere || Self.input(since: keyPressedAt ?? armed.at) {
                        SpeedyShared.log.notice("auto-send: the tech moved on while the chat app was waking; left ready to paste")
                        if let borrowToken { self.returnBorrowedClipboard(token: borrowToken) }
                        Toast.show("Screenshot ready. Move to \(name) to paste it", seconds: 2.5)
                        if self.armed?.id == armed.id { self.dwellTicks = 0; self.startHoverTimer() }
                        self.donePasting(generation)
                        return
                    }
                }
            }

            // Only the current ChatGPT app is known to route a paste to its message box from anywhere in the
            // window; its search and rename fields are the places a picture must not go.
            let result = await Paster.paste(
                into: app, window: window, expectedChangeCount: expected,
                refuseOtherTextFields: PasteTarget.matching(app, in: self.targets)?.refusesOtherTextFields ?? false,
                stillOnTarget: { !pointerMustStay || WindowHitTest.windowUnder()?.windowID == window.windowID })
            SpeedyShared.log.notice("paste result: \(String(describing: result), privacy: .public)")

            if let borrowToken {
                // Give ChatGPT a moment to read the picture before the old contents go back; straight away
                // when nothing was pasted.
                let delay: Duration = result == .pasted ? .milliseconds(1200) : .zero
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    self.returnBorrowedClipboard(token: borrowToken)
                }
            }

            // A paste by hand (hover, click, shortcut, multi-capture) into this window: whatever auto-send was
            // waiting there stands down and the tech sends it all themselves.
            if result == .pasted, !thenSend { self.pendingSends[windowID] = nil }

            // A newer screenshot arrived while this one was being pasted: it is the one that is armed now. When that
            // one is a session screenshot waiting to be pasted and sent too, this one still becomes a waiting send,
            // and the newer paste joins it (both go in one message) instead of leaving both unsent.
            let superseded = self.armed?.id != armed.id
            let joinedByNext = superseded && result == .pasted && thenSend && sendPlan != nil
                && self.deferredAutoSend.map { $0.armedID == self.armed?.id && !$0.multi } == true
            if joinedByNext { SpeedyShared.log.notice("auto-send: a newer session screenshot came in; it will join this send") }
            guard !superseded || joinedByNext else {
                if result == .pasted, thenSend {
                    self.pendingSends[windowID] = nil
                    Toast.show("Screenshot pasted into \(name), not sent: another one came in. Send them from \(name)", seconds: 3.5)
                }
                if self.armed != nil { self.dwellTicks = 0; self.startHoverTimer() }
                self.donePasting(generation)
                return
            }
            let fromFile = { if case .file = armed.ref { return true } else { return false } }()
            switch result {
            case .pasted where thenSend:
                if !superseded { self.disarm("pasted") }   // never the newer screenshot, which is still to go
                guard let composer = sendPlan else {
                    // Left in the chat app for the tech to finish: no jump back, no send.
                    Toast.show(notSentWhy == "draft"
                               ? "Screenshot pasted into \(name). There is already a message in progress, so it was not sent"
                               : "Screenshot pasted into \(name), not sent. Send it from \(name)", seconds: 4)
                    break
                }
                // An earlier auto-send waiting in this window stands down now; this one takes it all.
                let token = self.nextSendToken
                self.nextSendToken += 1
                self.pendingSends[windowID] = (token, self.pendingSends[windowID]?.images ?? 0, self.pendingSends[windowID]?.extras ?? 0)
                if let returnTo {
                    self.recentAutoPaste = (returnTo, app.processIdentifier, Date().addingTimeInterval(3))
                }
                let pastedAt = Date()
                try? await Task.sleep(for: .milliseconds(350))
                // The box must still hold nothing typed: keys the tech typed while the chat app was coming forward
                // land in its box, and those are not to be sent.
                let after = await Task.detached { () -> ComposerState in
                    var s = composer.read()
                    var tries = 0
                    while s.text == nil, tries < 6 {
                        try? await Task.sleep(for: .milliseconds(150))
                        tries += 1
                        s = composer.read()
                    }
                    return s
                }.value
                guard after.typed == "" else {
                    if self.pendingSends[windowID]?.token == token { self.pendingSends[windowID] = nil }
                    SpeedyShared.log.notice("auto-send: after the paste the box holds \(after.typed == nil ? "something unreadable" : "typing", privacy: .public); not sent")
                    Toast.show(after.typed == nil ? "Screenshot pasted into \(name), not sent. Send it from \(name)"
                                                  : "Screenshot pasted into \(name), not sent: some typing went into the message box", seconds: 4)
                    break
                }
                guard self.pendingSends[windowID]?.token == token else { break }   // a newer paste took over
                self.pendingSends[windowID] = (token, after.images, after.extras)
                // Back to the session (the send needs no focus), unless the tech has already started something else.
                var handoff = pastedAt
                var handedBack = false
                if let returnTo, !returnTo.isTerminated, Self.techIdle(since: pastedAt) {
                    Paster.bringBack(returnTo)
                    handoff = Date()
                    handedBack = true
                    self.recentAutoPaste = (returnTo, app.processIdentifier, Date().addingTimeInterval(1))
                }
                self.donePasting(generation)
                _ = await self.send(in: app, window: windowID, composer: composer, baselineImages: after.images,
                                    baselineExtras: after.extras, relocations: composer.relocations, handoff: handoff,
                                    handedBack: handedBack, returnTo: returnTo, token: token, byKey: keyPressedAt != nil)
            case .pasted:
                self.disarm("pasted")
                if let returnTo {
                    // Multi-capture: give the MCP a moment to take the picture, then back to the session.
                    try? await Task.sleep(for: .milliseconds(350))
                    Paster.bringBack(returnTo)
                    Toast.show("Added to the message in \(name). Send it when you have them all", seconds: 2)
                } else {
                    Toast.show(clipboardReplaced ? "Screenshot pasted into \(name). It is now on your clipboard too"
                                                 : "Screenshot pasted into \(name)", seconds: clipboardReplaced ? 3 : 1.4)
                }
            case .notTrusted:
                self.disarm("no accessibility")
                Toast.show("Speedy Bot needs Accessibility permission to paste", seconds: 3)
                self.state.showWindow?()
            case .clipboardChanged:
                self.disarm("clipboard changed")
            case .otherFieldFocused:
                if fromFile {
                    // The file is still there: stay armed, so clicking the message box and trying again works.
                    Toast.show("Click the message box first, then try again", seconds: 3.5)
                    self.sawPointerElsewhere = false
                    self.dwellTicks = 0
                    self.startHoverTimer()
                } else {
                    self.disarm("other field focused")
                    Toast.show("Screenshot is on the clipboard. Click the message box and press ⌘V", seconds: 3.5)
                }
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
            self.donePasting(generation)
        }
    }
}
