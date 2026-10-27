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
                keyIntent = nil
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
    /// The auto-send waiting to press Send in each chat window (by window): how many pictures and other composer
    /// buttons the box held once its paste had settled, and when that paste went in. A newer paste into the window
    /// replaces it (taking it over when it joins).
    private struct PendingSend { let token: Int; var images: Int; var extras: Int; var pastedAt: Date }
    private var pendingSends: [CGWindowID: PendingSend] = [:]
    /// Which paste holds `pasting`: only that paste may clear it (a waiting send finishing later must not).
    private var pasteGeneration = 0
    private var nextSendToken = 1
    /// A session screenshot that arrived while another paste was under way: pasted once that paste is done, if it
    /// is still the screenshot waiting.
    private var deferredAutoSend: (armedID: Int, returnTo: NSRunningApplication?, multi: Bool, at: Date)?
    /// A keypad paste waiting for the session-window capture it started (or one already under way when the key was
    /// pressed), for up to 8 s. Only that capture goes into the chat app this way (sent or not), and only while the
    /// app that was in front at the press still is; the capture failing, Off or another key drops it.
    private struct KeyIntent {
        let send: Bool
        let at: Date
        /// The capture counts if it started at or after this.
        let since: Date
        let frontPID: pid_t?
    }
    private var keyIntent: KeyIntent?
    /// A keypad paste whose screenshot arrived while another paste was under way: it goes once that one is done.
    private var deferredKeyPaste: (armedID: Int, send: Bool, pressedAt: Date, frontPID: pid_t?)?
    /// When the screenshot tool (the area selection or the corner preview) was last seen on screen.
    private var lastCaptureToolAt = Date.distantPast
    private var captureToolUp = false
    /// The app in front when the screenshot tool last came up (where that screenshot was taken), and when: a file
    /// the corner preview held back lands seconds later, wherever the tech is by then.
    private var captureStarted: (inSession: Bool, at: Date)?
    /// The app in front at the last look while the tool was not up.
    private var frontBeforeTool: NSRunningApplication?
    /// The latest screenshot file, whether or not it is still waiting: a second display's file of the same capture
    /// must not count as a screenshot of its own, even after the first was pasted.
    private var lastFile: (url: URL, at: Date)?
    /// The latest auto-send of a session screenshot: while it is waiting, or just after it went out, Paste and send
    /// has nothing new to send (it would capture and send the same screen again).
    private var recentSessionSend: (at: Date, token: Int, sent: Bool)?
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
        // A paste may have just put a screenshot there for the chat app to read: give it the same moment the paste
        // itself waits before the tech's clipboard comes back.
        if let token = borrow?.token {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { MainActor.assumeIsolated { self.returnBorrowedClipboard(token: token) } }
        }
        syncTriggers()
        deferredAutoSend = nil
        keyIntent = nil
        // A send already waiting (the last screenshot of a session, an answer still coming) finishes on its own;
        // ChatGPT's flag goes off once nothing is waiting any more.
        releaseIfIdle()
    }

    /// Speedy Bot switched Off: nothing waiting may still be sent.
    func cancelPendingSends() {
        cancelKeyIntent("Speedy Bot off")
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
        let toolUp = WindowHitTest.screenshotPreviewVisible()
        if toolUp {
            if !captureToolUp {
                let where_ = frontBeforeTool ?? NSWorkspace.shared.frontmostApplication
                captureStarted = (where_.map(FrontmostAppGate.isScreenConnect) ?? false, Date())
            }
            lastCaptureToolAt = Date()
        } else {
            frontBeforeTool = NSWorkspace.shared.frontmostApplication
        }
        captureToolUp = toolUp
        if previewDelaysFiles, toolUp != capturePending {
            capturePending = toolUp
            syncTriggers()
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

    /// The keypad's Paste / Paste-and-send keys: the screenshot goes into the chat app (and, for Paste and send, is
    /// sent the safe auto-send way, whether or not auto-send is switched on). A screenshot on its way is the one the
    /// key means (a capture of the session window under way, or a file the corner preview is holding back); else
    /// the one waiting, if it is under a minute old; else, when there is a session (`canCapture`), a new capture of
    /// its window (`capture` returns whether one started).
    func pasteFromKey(send: Bool, canCapture: Bool, captureInFlight: Bool, capture: () -> Bool) {
        guard pasteEnabled, source != nil else { Toast.show("Pasting screenshots is switched off in Speedy Bot", seconds: 2.5); return }
        guard !pasting else { Toast.show("A paste is already under way", seconds: 1.5); return }
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let toolUp = capturePending || WindowHitTest.screenshotPreviewVisible()
        if toolUp || (lastCaptureToolAt > lastScreenshotAt && now.timeIntervalSince(lastCaptureToolAt) < 1.5) {
            // A screenshot is being taken or saved right now (the area selection, the corner preview, or the file
            // being written just after). The key does not wait for it (it would act seconds later, wherever the
            // tech is by then): press again once it is there.
            Toast.show("A screenshot is still being taken. Press again once it is saved", seconds: 2.5)
            return
        }
        if captureInFlight || (sessionCaptureAt > lastScreenshotAt && now.timeIntervalSince(sessionCaptureAt) < 3) {
            // The Capture key (or ⇧⌘2) was pressed a moment ago and its picture is not here yet: that one.
            setKeyIntent(KeyIntent(send: send, at: now, since: min(sessionCaptureAt, now), frontPID: front))
            return
        }
        if send, armed == nil, let recent = recentSessionSend, now.timeIntervalSince(recent.at) < 10,
           recent.sent || pendingSends.values.contains(where: { $0.token == recent.token }) {
            // The session screenshot just taken is already going out (auto-send): not a second capture of it.
            Toast.show(recent.sent ? "That screenshot was just sent" : "That screenshot is already being sent", seconds: 2)
            return
        }
        if let armed, stillValid(armed), now.timeIntervalSince(armed.at) < keyFreshness {
            keyIntent = nil
            wakeForKey(send: send)
            runKeyPaste(send: send, armed: armed, pressedAt: now)
        } else if canCapture {
            setKeyIntent(KeyIntent(send: send, at: now, since: now, frontPID: front))
            if !capture() { cancelKeyIntent("the capture did not start") }
        } else {
            Toast.show("No recent screenshot to paste", seconds: 2)
        }
    }

    /// In Auto just after a session closed: a fresh screenshot that arrived before it closed (or just after, the
    /// corner preview holding it back). The paste keys may use only that.
    func hasShotFromSession(closedAt closed: Date) -> Bool {
        guard let armed, stillValid(armed) else { return false }
        return armed.at <= closed.addingTimeInterval(15) && Date().timeIntervalSince(armed.at) < keyFreshness
    }

    /// The capture of the session window produced no picture: nothing is on its way from it.
    func noteSessionCaptureFailed() {
        sessionCaptureAt = .distantPast
        cancelKeyIntent("the capture failed")
    }

    /// Another key was pressed, the capture failed, or Speedy Bot was switched off: a keypad paste still waiting for
    /// its screenshot is dropped.
    func cancelKeyIntent(_ why: String) {
        deferredKeyPaste = nil
        guard keyIntent != nil else { return }
        keyIntent = nil
        SpeedyShared.log.notice("keypad: paste request dropped (\(why, privacy: .public))")
        releaseIfIdle()
    }

    private func setKeyIntent(_ intent: KeyIntent) {
        keyIntent = intent
        wakeForKey(send: intent.send)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.1) { MainActor.assumeIsolated { self.expireKeyIntent() } }
    }

    private func keyIntentLive(_ intent: KeyIntent, now: Date = Date()) -> Bool { now.timeIntervalSince(intent.at) < 8 }

    /// The screenshot a keypad paste was waiting for never came.
    private func expireKeyIntent() {
        guard let intent = keyIntent, !keyIntentLive(intent) else { return }
        keyIntent = nil
        SpeedyShared.log.notice("keypad: the capture the key was waiting for never arrived")
        Toast.show("The capture did not come, so nothing was pasted", seconds: 2.5)
        releaseIfIdle()
    }

    /// Reading the message box needs ChatGPT's tree, which is only kept up ahead of time while auto-send is on.
    private func wakeForKey(send: Bool) {
        guard send, targets.contains(.chatGPT) else { return }
        for app in NSWorkspace.shared.runningApplications where PasteTarget.chatGPT.matches(app) {
            ChatSend.wakeAccessibility(pid: app.processIdentifier)
        }
    }

    /// A keypad paste whose screenshot came after the press: only if the app in front then still is (never pulling
    /// the chat app over some other app the tech has moved on to).
    private func runKeyPasteIfStillThere(send: Bool, armed: Armed, pressedAt: Date, frontPID: pid_t?) {
        if frontPID == nil || Date().timeIntervalSince(pressedAt) < 2 || NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID {
            runKeyPaste(send: send, armed: armed, pressedAt: pressedAt)
        } else {
            SpeedyShared.log.notice("keypad: the tech moved on before the screenshot arrived; left ready to paste")
            Toast.show("Screenshot ready. Move to \(PasteTarget.names(targets)) to paste it", seconds: 2.5)
            releaseIfIdle()
        }
    }

    private func runKeyPaste(send: Bool, armed: Armed, pressedAt: Date) {
        guard let target = shortcutTarget() else {
            Toast.show("Open \(PasteTarget.names(targets)) first", seconds: 2.5)
            releaseIfIdle()
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
        // The keypad was waiting for this screenshot: it goes the way the key said, if the tech is still where the
        // key was pressed (never pulling the chat app over some other app they have moved on to).
        if let intent = keyIntent, keyIntentLive(intent) {
            // Only the capture of the session window the key is waiting for.
            if Date().timeIntervalSince(sessionCaptureAt) < 4, sessionCaptureAt >= intent.since {
                keyIntent = nil
                sessionCaptureAt = .distantPast   // that capture has arrived: no later screenshot is it
                if pasting {
                    deferredKeyPaste = (armed.id, intent.send, intent.at, intent.frontPID)
                } else {
                    runKeyPasteIfStillThere(send: intent.send, armed: armed, pressedAt: intent.at, frontPID: intent.frontPID)
                }
                return
            }
            // Not the one the key is waiting for: it keeps waiting, and this one goes the usual way.
        } else if keyIntent != nil {
            keyIntent = nil
            releaseIfIdle()
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
        if windowCapture { sessionCaptureAt = .distantPast }   // that capture has arrived: no later screenshot is it
        let multi = multiCapture && windowCapture
        // A file the corner preview held back was taken where the screenshot tool came up, not where the tech is
        // now: it counts as the session's only if it was taken there.
        var takenInSession = true
        if previewDelaysFiles, case .file = armed.ref, !windowCapture, !viaOurPaste {
            takenInSession = captureStarted.map { $0.inSession && Date().timeIntervalSince($0.at) < 30 } ?? false
        }
        // Only a screenshot from a session that is still in front, or the session-window capture: a file that lands
        // seconds later, after the tech has moved on to another app, must not pull the chat app over it.
        let auto = autoSendFromSession && takenInSession && (viaOurPaste || Date().timeIntervalSince(sessionInFrontAt) < memory) && (session != nil || windowCapture)
        guard multi || auto else {
            if autoSendFromSession, takenInSession, session == nil, Date().timeIntervalSince(sessionInFrontAt) < memory {
                // Taken in the session, but the tech has left it since: it waits for a move to the chat app.
                SpeedyShared.log.notice("auto-send: the screenshot came after the tech left the session; left ready to paste")
                Toast.show("Screenshot ready. Move to \(PasteTarget.names(targets)) to paste it", seconds: 2.5)
            }
            return
        }
        if pasting {
            // Another paste is under way; this one goes once that is done (if it is still the one waiting).
            deferredAutoSend = (armed.id, session, multi, Date())
            return
        }
        runSessionPaste(returnTo: session, multi: multi)
    }

    private func runSessionPaste(returnTo session: NSRunningApplication?, multi: Bool) {
        guard let armed else { return }
        guard let target = shortcutTarget() else {
            Toast.show("Open a \(PasteTarget.names(targets)) window to send screenshots to", seconds: 2.5)
            return
        }
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
        // A capture of several displays saves one file per display, named alike ("… 9.15.32 PM.png", "… 9.15.32 PM
        // (2).png"); the first one (the main display) stays armed. Any other file is a screenshot of its own.
        if let last = lastFile, Date().timeIntervalSince(last.at) < 3, Self.sameCapture(last.url, url) { return }
        lastFile = (url, Date())
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

    nonisolated static func sameCapture(_ a: URL, _ b: URL) -> Bool {
        let stemA = a.deletingPathExtension().lastPathComponent, stemB = b.deletingPathExtension().lastPathComponent
        func base(_ s: String) -> String { s.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression) }
        return stemA != stemB && base(stemA) == base(stemB)
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
        deferredKeyPaste = nil
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
            if recentSessionSend?.token == token { recentSessionSend = sent ? (Date(), token, true) : nil }
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
        // first (right after the hand-back it still reads as the one in front), and is only decided a second later:
        // when the session is closing, macOS brings the chat app forward by itself, and then only input there
        // counts. A paste of ours under way (which brings the chat app forward) does not count, and neither do the
        // keys that took a screenshot: input followed within 1.5 s by a screenshot arriving, or within 1 s by the
        // screenshot tool coming up (choosing an area can take a while; Esc there is not work in the chat either).
        // Any other input counts once 2 s have passed; until then the send waits.
        enum ChatActivity { case none, maybe, working }
        var leftChat = false                // the chat app has been seen behind another app since the paste
        var chatInFront = true              // as last seen
        var chatInFrontSince = handoff      // since when the chat app has been in front this time
        var inputBaseline = handoff         // input before this does not count
        var chatInputAt: Date?              // the first input in the chat app since then
        var captureToolSeenAt: Date?        // when the screenshot tool was first seen up after that input
        var toolWasUp = false               // the screenshot tool, as last seen
        var toolUpBeforeInput = false       // it was already up (an earlier screenshot) when that input came
        func sessionGone() -> Bool {
            guard let session = returnTo else { return true }
            if session.isTerminated || kill(session.processIdentifier, 0) != 0 { return true }
            return !SessionWindows.hasWindow(pid: session.processIdentifier)
        }
        func chatActivity() -> ChatActivity {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == pid else {
                if front != nil { leftChat = true; chatInFront = false }
                return .none
            }
            if !chatInFront {
                chatInFront = true
                chatInFrontSince = Date()
                inputBaseline = max(inputBaseline, chatInFrontSince)
                chatInputAt = nil
                captureToolSeenAt = nil
                toolWasUp = WindowHitTest.screenshotPreviewVisible()
            }
            guard !pasting else { return .none }
            let now = Date()
            if handedBack, leftChat {
                if now.timeIntervalSince(chatInFrontSince) < 1 { return .maybe }
                if !sessionGone() { return .working }
            }
            let toolUp = WindowHitTest.screenshotPreviewVisible()
            defer { toolWasUp = toolUp }
            let lastInput = now.addingTimeInterval(-Self.secondsSinceInput())
            if chatInputAt == nil, lastInput > inputBaseline { chatInputAt = lastInput; toolUpBeforeInput = toolWasUp }
            guard let first = chatInputAt else { return .none }
            // With an earlier screenshot's tool (its corner preview) already up, the input cannot be told apart
            // from work in the chat app: it counts.
            if !toolUpBeforeInput {
                if toolUp, captureToolSeenAt == nil { captureToolSeenAt = now }
                let tookScreenshot = captureToolSeenAt.map { $0.timeIntervalSince(first) <= 1 } ?? false
                if lastScreenshotAt > first, lastScreenshotAt.timeIntervalSince(first) <= 1.5 || tookScreenshot {
                    inputBaseline = lastScreenshotAt
                    chatInputAt = nil
                    captureToolSeenAt = nil
                    return Self.input(since: inputBaseline) ? .maybe : .none
                }
                if tookScreenshot {
                    if toolUp { return now.timeIntervalSince(first) < 60 ? .maybe : .working }
                    inputBaseline = now   // the tool closed with no screenshot (Esc)
                    chatInputAt = nil
                    captureToolSeenAt = nil
                    return .none
                }
            }
            return now.timeIntervalSince(first) < 2 ? .maybe : .working
        }
        var lastProgress = 0.0          // reset while an answer is in progress
        var unreadableSince: Double?
        var presses = 0
        // A drag since the paste that was not taking a screenshot may have dropped a file onto the window: from then
        // on nothing new in the box is taken in as the screenshot's own.
        var takeInFrozen = false
        var dragsCheckedTo = pendingSends[window]?.pastedAt ?? handoff
        while true {
            if droppedSomething(since: dragsCheckedTo) { takeInFrozen = true }
            dragsCheckedTo = Date()
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
            // The picture may still be settling into the box (its chip appears and changes as it uploads, which keeps
            // Send greyed out): take that in for 1.5 s, and up to 4 s while the upload runs as long as no mouse button
            // has gone down since the paste, never after a drag that may have dropped something; and let a screenshot
            // that joins this send know.
            let pastedAt = pendingSends[window]?.pastedAt ?? handoff
            if !takeInFrozen,
               elapsed() < 1.5 || (elapsed() < 4 && !s.streaming && s.sendButton != nil && s.sendEnabled == false && !Self.mouseInput(since: pastedAt)) {
                imagesBase = max(imagesBase, s.images)
                extrasBase = max(extrasBase, s.extras)
                if stillOurs() { pendingSends[window]?.images = imagesBase; pendingSends[window]?.extras = extrasBase }
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

    /// A drag (hardware) since then that was not choosing a screenshot area: it may have dropped a file somewhere.
    private func droppedSomething(since: Date) -> Bool {
        let gone = Date().timeIntervalSince(since)
        guard gone > 0 else { return false }
        let dragged = [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < gone }
        guard dragged else { return false }
        let toolAround = WindowHitTest.screenshotPreviewVisible() || Date().timeIntervalSince(lastCaptureToolAt) < 0.6
        return !toolAround
    }

    /// A mouse button pressed, or a drag, (hardware) since then: the only way a file can be dropped onto a window.
    private static func mouseInput(since: Date) -> Bool {
        let gone = Date().timeIntervalSince(since)
        guard gone > 0 else { return false }
        return [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
            .contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < gone }
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

    /// At launch: ChatGPT's flag left on by an earlier run becomes this run's, and goes off at once unless auto-send
    /// can use it.
    func adoptLeftoverWake() {
        ChatSend.adoptLeftovers()
        releaseIfIdle()
    }

    /// Auto-send is off or Speedy Bot is stopping: ChatGPT no longer needs its tree kept up for us.
    private func releaseChatApps() { ChatSend.releaseAccessibility() }

    /// ChatGPT's flag goes off once nothing is waiting to send and auto-send cannot run (stopped, paste off,
    /// auto-send off, or ChatGPT not among the chat apps).
    private func releaseIfIdle() {
        // A paste under way, or one the keypad has asked for, may still need to read the message box.
        let keyWaiting = keyIntent.map { keyIntentLive($0) } ?? false
        guard pendingSends.isEmpty, !pasting, !keyWaiting else { return }
        if source == nil || !pasteEnabled || !autoSendFromSession || !targets.contains(.chatGPT) { releaseChatApps() }
    }

    /// The paste `generation` is finished (or abandoned): a session screenshot that came in meanwhile goes now,
    /// if the tech is still where it was taken and has not started something else since.
    private func donePasting(_ generation: Int) {
        guard generation == pasteGeneration, pasting else { return }
        pasting = false
        // A keypad paste whose screenshot came in meanwhile goes first, the way the key said.
        if let key = deferredKeyPaste {
            deferredKeyPaste = nil
            deferredAutoSend = nil
            if let armed, armed.id == key.armedID, Date().timeIntervalSince(key.pressedAt) < 30 {
                runKeyPasteIfStillThere(send: key.send, armed: armed, pressedAt: key.pressedAt, frontPID: key.frontPID)
            } else {
                releaseIfIdle()
            }
            return
        }
        guard let deferred = deferredAutoSend else { releaseIfIdle(); return }
        deferredAutoSend = nil
        guard armed?.id == deferred.armedID, Date().timeIntervalSince(deferred.at) < 15 else { releaseIfIdle(); return }
        if !stillThere(deferred.returnTo) {
            SpeedyShared.log.notice("auto-send: the tech moved on before the held-back screenshot's turn; left ready to paste")
            Toast.show("Screenshot ready. Move to \(PasteTarget.names(targets)) to paste it", seconds: 2.5)
            releaseIfIdle()
            return
        }
        runSessionPaste(returnTo: deferred.returnTo, multi: deferred.multi)
    }

    /// A paste from a session that is not handing over to a send: the session comes back to the front (after a
    /// moment for the picture to land), so the tech's next keys do not go into the chat app's message box.
    private func giveSessionBack(_ session: NSRunningApplication?, from chat: NSRunningApplication) {
        guard let session, !session.isTerminated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                guard !session.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == chat.processIdentifier else { return }
                Paster.bringBack(session)
            }
        }
    }

    /// The tech is still where the screenshot was taken: that session in front, or the chat app an auto-paste of
    /// ours has just brought forward over it.
    private func stillThere(_ session: NSRunningApplication?) -> Bool {
        guard let session else { return true }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == session.processIdentifier { return true }
        guard let recent = recentAutoPaste else { return false }
        return Date() < recent.until && front == recent.chatPID && recent.session.processIdentifier == session.processIdentifier
    }

    private func paste(into app: NSRunningApplication, window: WindowUnderPointer, armed: Armed, pointerMustStay: Bool,
                       thenSend: Bool = false, returnTo: NSRunningApplication? = nil, keyPressedAt: Date? = nil) {
        pasteGeneration += 1
        let generation = pasteGeneration
        pasting = true
        hoverTimer?.invalidate(); hoverTimer = nil
        Task { @MainActor in
            let name = PasteTarget.matching(app, in: self.targets)?.title ?? "the chat"
            let windowID = window.windowID
            var borrowToken: Int?
            /// Not now after all: the screenshot stays ready for a move to the chat app. If an earlier paste of ours
            /// left the chat app in front over the session, the session comes back.
            @MainActor func leaveReady(_ why: String, toast: String?) {
                SpeedyShared.log.notice("auto-send: \(why, privacy: .public); left ready to paste")
                if let borrowToken { self.returnBorrowedClipboard(token: borrowToken) }
                if let returnTo, !returnTo.isTerminated, let recent = self.recentAutoPaste, recent.chatPID == app.processIdentifier,
                   Date() < recent.until.addingTimeInterval(5), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    Paster.bringBack(returnTo)
                }
                if let toast { Toast.show(toast, seconds: 2.5) }
                if self.armed?.id == armed.id { self.dwellTicks = 0; self.startHoverTimer() }
                self.donePasting(generation)
            }
            let ready = "Screenshot ready. Move to \(name) to paste it"
            @MainActor func stillWanted() -> Bool { self.pasteEnabled && self.source != nil && (!thenSend || keyPressedAt != nil || self.autoSendFromSession) }
            /// Typing, clicking or scrolling in the last half second; or taking the next screenshot (its tool up, or
            /// a modifier key held for its shortcut).
            @MainActor func busy() -> (working: Bool, capturing: Bool) {
                let working = Self.secondsSinceInput() < 0.5
                    || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel) < 0.5
                let capturing = WindowHitTest.screenshotPreviewVisible()
                    || !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty
                return (working, capturing)
            }

            // Never pull the chat app forward over the tech's work in the session (their next keys would land in its
            // message box): wait until they have not typed, clicked or scrolled for half a second (until 3 s after
            // the screenshot came, or the key was pressed), or finished taking the next screenshot (until 10 s; that
            // one then joins this). Otherwise the screenshot stays ready. Nothing is put on the clipboard while
            // waiting. The same is checked again right before the paste keystroke.
            var quietSince = Date()
            if returnTo != nil {
                let from = keyPressedAt ?? armed.at
                var b = busy()
                while b.working || b.capturing, Date().timeIntervalSince(from) < (b.capturing ? 10 : 3) {
                    try? await Task.sleep(for: .milliseconds(100))
                    b = busy()
                }
                quietSince = Date()
                if b.working || b.capturing {
                    leaveReady(b.capturing ? "the next screenshot is still being taken" : "the tech is busy in the session", toast: ready)
                    return
                }
                if !self.stillThere(returnTo) { leaveReady("the tech moved on", toast: ready); return }
                if !stillWanted() { leaveReady("switched off", toast: nil); return }
            }
            if case .clipboard(let count) = armed.ref, NSPasteboard.general.changeCount != count {
                // A newer screenshot (or a copy) has replaced it on the clipboard: nothing of it is left to paste.
                if self.armed?.id == armed.id { self.disarm("clipboard changed") }
                if thenSend { Toast.show("That screenshot was replaced on the clipboard before it could be pasted", seconds: 2.5) }
                self.donePasting(generation)
                return
            }

            // A saved file has to be put on the clipboard for the paste. What the tech had copied is kept and
            // put back afterwards, because in this mode a screenshot is not supposed to touch the clipboard.
            let expected: Int
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

            // Auto-send must never send anything the tech has put in the box, so the message box of this very window
            // is read first: any typed text, or pictures and files other than our own auto-send still waiting there,
            // mean paste only. A box that cannot be read within 3 s (the tree still waking) also means paste only.
            var sendPlan: Composer?
            var notSentWhy = ""
            var lookRelocations = 0
            if thenSend {
                let composer = Composer(pid: app.processIdentifier, windowID: windowID)
                let lookStarted = Date()
                var before = await Task.detached { () -> ComposerState in
                    let deadline = Date().addingTimeInterval(3)
                    var s = composer.read()
                    while s.text == nil, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(250))
                        s = composer.read()
                    }
                    return s
                }.value
                let slowLook = Date().timeIntervalSince(lookStarted) > 0.6
                var ours = self.pendingSends[windowID]   // an earlier auto-send still waiting in this window
                var waitedForOurs = false
                if let pending = ours, before.typed == "", Date().timeIntervalSince(pending.pastedAt) < 1.5 {
                    // Our own screenshot before this one may still be settling into the box (its send pauses while
                    // this paste runs): give it the same 1.5 s that send would have, and take that in, so this one
                    // can join it.
                    waitedForOurs = true
                    try? await Task.sleep(for: .milliseconds(Int((1.5 - Date().timeIntervalSince(pending.pastedAt)) * 1000)))
                    let settled = await Task.detached { composer.read() }.value
                    // Not if something may have been dropped in since this screenshot came (a drag that was not
                    // taking a screenshot).
                    if settled.typed == "", self.pendingSends[windowID]?.token == pending.token, !self.droppedSomething(since: armed.at) {
                        self.pendingSends[windowID]?.images = max(pending.images, settled.images)
                        self.pendingSends[windowID]?.extras = max(pending.extras, settled.extras)
                    }
                    ours = self.pendingSends[windowID]
                    before = settled
                }
                lookRelocations = composer.relocations
                if before.typed == nil {
                    notSentWhy = "unreadable"
                } else if before.typed?.isEmpty == false {
                    notSentWhy = "draft"
                } else if self.droppedSomething(since: max(armed.at, lookStarted.addingTimeInterval(-1))) {
                    notSentWhy = "dropped"   // a drag just ended: what it dropped may not show in the box yet
                } else if let ours, before.images <= ours.images, before.extras <= ours.extras {
                    sendPlan = composer   // only our own pending screenshots are there: this one joins them
                } else if (!before.streaming && before.sendButton != nil) || (before.streaming && before.extras > 0) {
                    // Pictures or files already in the box. A Send button means the box holds something; while an
                    // answer runs the Send button is hidden, so any composer button beyond its fixed ones (an
                    // attachment's "remove …") counts. The picture count is not used here: ChatGPT shows a picture
                    // of its own near an empty box (measured: 1 with nothing in it).
                    notSentWhy = "draft"
                } else {
                    sendPlan = composer
                }
                SpeedyShared.log.notice("auto-send: before the paste: \(sendPlan != nil ? (ours != nil ? "joining the pending send" : "box clear") : notSentWhy, privacy: .public), streaming=\(before.streaming), pictures=\(before.images), extras=\(before.extras), composer=[\(before.buttons.joined(separator: ", "), privacy: .public)]")
                // A slow look (the tree was still waking) or the wait for our own screenshot: the tech must still be
                // where the screenshot was taken, and (unless a key was just pressed for this) not have started
                // anything since the quiet moment above.
                if (slowLook || waitedForOurs) && returnTo != nil {
                    if !self.stillThere(returnTo) || Self.input(since: quietSince) {
                        leaveReady("the tech moved on while the chat app was being read", toast: ready)
                        return
                    }
                }
            }
            if !stillWanted() { leaveReady("switched off", toast: nil); return }

            // While this paste has the chat app in front, a screenshot still counts as taken in the session (the
            // tech's next one may land before the paste is done).
            if let returnTo {
                self.recentAutoPaste = (returnTo, app.processIdentifier, Date().addingTimeInterval(5))
            }

            // Only the current ChatGPT app is known to route a paste to its message box from anywhere in the
            // window; its search and rename fields are the places a picture must not go.
            let result = await Paster.paste(
                into: app, window: window, expectedChangeCount: expected,
                refuseOtherTextFields: PasteTarget.matching(app, in: self.targets)?.refusesOtherTextFields ?? false,
                stillOnTarget: {
                    // From a session: no key, click or drag since the quiet moment (it would have gone into the chat
                    // app). By hover: the pointer still on the window.
                    (returnTo == nil || !Self.input(since: quietSince))
                        && (!pointerMustStay || WindowHitTest.windowUnder()?.windowID == window.windowID)
                })
            SpeedyShared.log.notice("paste result: \(String(describing: result), privacy: .public)")
            // Nothing went in: the chat app is not in front for us any more (a clipboard change is the tech's next
            // screenshot landing, which still needs to count as taken in the session).
            if returnTo != nil, result != .pasted, result != .clipboardChanged, self.recentAutoPaste?.chatPID == app.processIdentifier {
                self.recentAutoPaste = nil
            }

            if let borrowToken {
                // Give ChatGPT a moment to read the picture before the old contents go back; straight away
                // when nothing was pasted.
                let delay: Duration = result == .pasted ? .milliseconds(1200) : .zero
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    self.returnBorrowedClipboard(token: borrowToken)
                }
            }

            // A paste by hand (hover, click, shortcut, multi-capture), or one that is not to be sent, into this window:
            // whatever auto-send was waiting there stands down and the tech sends it all themselves.
            let earlierWaiting = self.pendingSends[windowID] != nil
            if result == .pasted, !thenSend || sendPlan == nil { self.pendingSends[windowID] = nil }

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
                } else if result == .clipboardChanged, thenSend {
                    Toast.show("That screenshot was replaced on the clipboard before it could be pasted", seconds: 2.5)
                }
                // Unless a paste of ours follows straight away, the session comes back to the front.
                if self.deferredAutoSend == nil, self.deferredKeyPaste == nil { self.giveSessionBack(returnTo, from: app) }
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
                    Toast.show(earlierWaiting ? "Screenshot pasted into \(name), not sent, with the one before it. Send them from \(name)"
                               : notSentWhy == "draft" ? "Screenshot pasted into \(name). There is already a message in progress, so it was not sent"
                               : notSentWhy == "dropped" ? "Screenshot pasted into \(name), not sent: something may have been dropped into the message box"
                               : "Screenshot pasted into \(name), not sent. Send it from \(name)", seconds: 4)
                    self.giveSessionBack(returnTo, from: app)
                    break
                }
                // An earlier auto-send waiting in this window stands down now; this one takes it all.
                let token = self.nextSendToken
                self.nextSendToken += 1
                let pastedAt = Date()
                if keyPressedAt == nil { self.recentSessionSend = (pastedAt, token, false) }
                self.pendingSends[windowID] = PendingSend(token: token, images: self.pendingSends[windowID]?.images ?? 0,
                                                          extras: self.pendingSends[windowID]?.extras ?? 0, pastedAt: pastedAt)
                if let returnTo {
                    self.recentAutoPaste = (returnTo, app.processIdentifier, Date().addingTimeInterval(3))
                }
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
                    // The tech was working in the session: their next keys belong there, not in the chat app.
                    if let returnTo, !returnTo.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                        Paster.bringBack(returnTo)
                    }
                    break
                }
                guard self.pendingSends[windowID]?.token == token else { break }   // a newer paste took over
                guard composer.relocations == lookRelocations else {
                    // The message box was replaced between the look and the paste (another conversation): not sent.
                    self.pendingSends[windowID] = nil
                    SpeedyShared.log.notice("auto-send: the message box changed before the paste; not sent")
                    Toast.show("Screenshot pasted into \(name), not sent: the conversation changed. Send it from \(name)", seconds: 4)
                    if let returnTo, !returnTo.isTerminated { Paster.bringBack(returnTo) }
                    break
                }
                self.pendingSends[windowID]?.images = after.images
                self.pendingSends[windowID]?.extras = after.extras
                // Back to the session (the send needs no focus): any key or click in the moment the chat app was in
                // front was meant for the session.
                var handoff = pastedAt
                var handedBack = false
                if let returnTo, !returnTo.isTerminated {
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
                } else if earlierWaiting {
                    Toast.show("Screenshot pasted into \(name). The one before it was not sent either; send them from \(name)", seconds: 4)
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
                if thenSend, let returnTo {
                    // Usually the tech's next screenshot, which is pasted next; if nothing of ours follows, the session
                    // comes back to the front.
                    Toast.show("That screenshot was replaced on the clipboard before it could be pasted", seconds: 2.5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        MainActor.assumeIsolated {
                            if !self.pasting, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                                Paster.bringBack(returnTo)
                            }
                        }
                    }
                }
            case .otherFieldFocused where returnTo != nil:
                // From a session: the tech is not in the chat app to click its message box. Ready for a move there.
                self.giveSessionBack(returnTo, from: app)
                Toast.show("Screenshot not pasted: \(name) had another field selected. Move to \(name) to paste it", seconds: 3)
                self.sawPointerElsewhere = false
                self.dwellTicks = 0
                self.startHoverTimer()
            case .pointerLeft where returnTo != nil:
                // The tech typed or clicked just before the paste keystroke: nothing went in, the session comes back.
                self.giveSessionBack(returnTo, from: app)
                Toast.show(ready, seconds: 2.5)
                self.sawPointerElsewhere = false
                self.dwellTicks = 0
                self.startHoverTimer()
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
                // Nothing went in. A paste from the session gives the session back, and says so.
                if let returnTo {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { Paster.bringBack(returnTo) }
                    Toast.show(result == .modifiersHeld ? "Screenshot not pasted: a key was held down. Move to \(name) to paste it"
                                                        : "Screenshot not pasted: \(name) did not come forward. Move to \(name) to paste it", seconds: 3)
                }
                // Stay armed: let the tech move away and come back to try again.
                self.sawPointerElsewhere = false
                self.dwellTicks = 0
                self.startHoverTimer()
            }
            self.donePasting(generation)
        }
    }
}
