import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Which window of the session app had keyboard focus when the shortcut was pressed, checkable from the
/// typing thread. ScreenConnect pops its Chat window to the front when the customer sends a message; typing
/// must stop the moment that happens, or the rest of the clipboard (and its Return) goes to the customer.
struct FocusProbe: @unchecked Sendable {
    let pid: pid_t
    let window: AXUIElement?

    /// `answered` is false when the app did not reply (busy, timed out): that is "unknown", not "changed".
    private static func focusedWindow(_ pid: pid_t) -> (answered: Bool, window: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v)
        guard err == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else {
            return (err == .noValue, nil)   // .noValue is a real answer: the app has no focused window
        }
        return (true, (v as! AXUIElement))
    }

    private static func title(_ window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.25)
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &v) == .success ? v as? String : nil
    }

    static func isChatOrStatus(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.hasPrefix("Chat - ") || title.hasPrefix("Status - ")
    }

    static func capture(pid: pid_t) -> (probe: FocusProbe, title: String?) {
        let w = focusedWindow(pid).window
        return (FocusProbe(pid: pid, window: w), w.flatMap(title))
    }

    /// False once keyboard focus is known to have moved to another window of the app.
    func stillFocused() -> Bool {
        let now = Self.focusedWindow(pid)
        guard now.answered else { return true }
        guard let window else {
            // The app gave no window at the start, so there is nothing to compare; still never type into chat.
            return !Self.isChatOrStatus(now.window.flatMap(Self.title))
        }
        guard let current = now.window else { return false }
        return CFEqual(current, window)
    }
}

/// Feature B: Cmd+Shift+V while a ScreenConnect session is in front TYPES the clipboard text into the remote
/// machine, key by key. Esc stops it. The shortcut is only claimed while ScreenConnect is frontmost, so
/// Cmd+Shift+V keeps its normal meaning everywhere else.
@MainActor
final class RemoteTypingController {
    private unowned let state: AppState
    private var gate: FrontmostAppGate?
    private var hotKeyCode = CGKeyCode(kVK_ANSI_V)
    private var hotKeyModifiers = cmdKey | shiftKey
    private var escKey: GlobalHotKey?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false

    private var typing = false
    private var targetPID: pid_t = 0
    private let cancelled = AtomicFlag()
    private let sessionInFront = AtomicFlag()
    /// A long clipboard needs the shortcut twice; this remembers the first press.
    private var pendingConfirm: (changeCount: Int, until: Date)?

    /// Above this many characters the shortcut has to be pressed twice (ScreenConnect's own warning is at 200).
    private let confirmAbove = 500

    init(state: AppState) { self.state = state }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            if gate == nil { build() }
            gate?.enabled = true
        } else {
            gate?.enabled = false
            cancelled.set(true)
            pendingConfirm = nil
        }
    }

    private func build() {
        registerHotKey()
        escKey = GlobalHotKey(keyCode: kVK_Escape, carbonModifiers: 0) { [weak self] in self?.cancelled.set(true) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only the very app the typing started in counts, not any ScreenConnect process.
                self.sessionInFront.set(NSWorkspace.shared.frontmostApplication?.processIdentifier == self.targetPID)
            }
        })
        // The V key moves when the tech switches keyboard layout; move the shortcut with it.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        })
    }

    /// (Re)creates the shortcut: the tech's own if they recorded one, otherwise Cmd+Shift+V on the key that
    /// means V while Command is held on the current layout.
    private func registerHotKey() {
        let custom = state.typingShortcut
        let code = custom.map { CGKeyCode($0.keyCode) } ?? LayoutKeyMap.keyCodeWithCommand(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let mods = custom?.carbonModifiers ?? (cmdKey | shiftKey)
        if gate != nil, code == hotKeyCode, mods == hotKeyModifiers { return }
        gate?.stop()
        hotKeyCode = code
        hotKeyModifiers = mods
        let hk = GlobalHotKey(keyCode: Int(code), carbonModifiers: mods) { [weak self] in self?.fire() }
        let g = FrontmostAppGate(hotKey: hk, matches: FrontmostAppGate.isScreenConnect)
        g.enabled = enabled
        gate = g
    }

    /// The tech recorded a different shortcut (or went back to the standard one).
    func shortcutChanged() {
        if gate != nil { registerHotKey() }
    }

    // MARK: the shortcut

    /// The keypad's Type key: the same as the shortcut, so a ScreenConnect session has to be in front.
    func typeFromKey() {
        guard enabled else { Toast.show("Typing into ScreenConnect is switched off in Speedy Bot", seconds: 2.5); return }
        guard let front = NSWorkspace.shared.frontmostApplication, FrontmostAppGate.isScreenConnect(front) else {
            Toast.show("Click into the ScreenConnect session first, then press Type", seconds: 2.5)
            return
        }
        fire()
    }

    private func fire() {
        guard !typing else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, FrontmostAppGate.isScreenConnect(front) else { return }
        guard Permissions.accessibilityTrusted, Permissions.canPostEvents else {
            Toast.show("Speedy Bot needs Accessibility permission to type", seconds: 3)
            state.showWindow?()
            return
        }
        let pb = NSPasteboard.general
        guard let raw = pb.string(forType: .string), !raw.isEmpty else {
            Toast.show(PasteboardWatcher.looksLikeScreenshot(pb)
                       ? "The clipboard holds a screenshot, not text. Copy the text again" : "Clipboard has no text to type", seconds: 3)
            return
        }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A trailing line break would press Return for the tech (submitting a password or running a command).
        while text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { Toast.show("Clipboard has no text to type"); return }

        // ScreenConnect's own Chat and Status windows belong to the same app. Typing a password into chat
        // and pressing Return would send it to the customer.
        let focus = FocusProbe.capture(pid: front.processIdentifier)
        if FocusProbe.isChatOrStatus(focus.title) {
            Toast.show("That is the ScreenConnect chat window. Click the remote screen first", seconds: 3)
            return
        }
        if TextTyper.capsLockOn {
            Toast.show("Caps Lock is on. Turn it off and press \(state.typingShortcutLabel) again", seconds: 3)
            return
        }
        guard let (plan, options) = typingPlan(text) else { return }
        guard !plan.keys.isEmpty else { Toast.show("Clipboard has no text to type"); return }

        if text.count > confirmAbove {
            if let p = pendingConfirm, p.changeCount == pb.changeCount, Date() < p.until {
                pendingConfirm = nil
            } else {
                pendingConfirm = (pb.changeCount, Date().addingTimeInterval(5))
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                Toast.show("Press \(state.typingShortcutLabel) again to type \(text.count) characters (\(lines) line\(lines == 1 ? "" : "s"))", seconds: 4)
                return
            }
        }
        start(plan: plan, options: options, focus: focus.probe)
    }

    /// The keys for `text` on this Mac's layout, or nil (with a note) when the layout cannot be read or cannot type
    /// every character: all or nothing, since a password with one character missing is a wrong password, and a
    /// command with a character missing is a different command.
    private func typingPlan(_ text: String) -> (TypingPlan, TypingOptions)? {
        guard let keyMap = LayoutKeyMap.current() else {
            Toast.show("Could not read this Mac's keyboard layout")
            return nil
        }
        let options = state.fastTyping ? TypingOptions.fast : TypingOptions()
        let plan = TextTyper.plan(text, keyMap: keyMap, options: options)
        guard plan.skipped.isEmpty else {
            var seen = Set<Character>()
            let sample = String(plan.skipped.filter { seen.insert($0).inserted }.prefix(8))
            Toast.show("This keyboard cannot type: \(sample)  Nothing was typed", seconds: 4)
            SpeedyShared.log.notice("typing refused: characters not on this keyboard layout")
            return nil
        }
        return (plan, options)
    }

    // MARK: 1Password

    private lazy var picker = PasswordPicker()

    /// The keypad's Password key (or the menu): a search over the local 1Password vault, opened over the ScreenConnect
    /// session in front; the pick is typed into that session window key by key, never through the clipboard.
    func passwordFromKey() {
        guard enabled else { Toast.show("Typing into ScreenConnect is switched off in Speedy Bot", seconds: 2.5); return }
        guard !typing else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, FrontmostAppGate.isScreenConnect(front) else {
            Toast.show("Click into the ScreenConnect session first, then press Password", seconds: 2.5)
            return
        }
        let focus = FocusProbe.capture(pid: front.processIdentifier)
        if FocusProbe.isChatOrStatus(focus.title) {
            Toast.show("That is the ScreenConnect chat window. Click the remote screen first", seconds: 3)
            return
        }
        guard OnePassword.cliPath != nil else { Toast.show(OnePassword.Failure.notInstalled.message, seconds: 4); return }
        let window = WindowHitTest.frontWindow(ofPID: front.processIdentifier)
        SpeedyShared.log.notice("1Password: picker opened over the session")
        picker.show(session: focus.title ?? "") { [weak self] item, withUser in
            self?.typePick(item, withUser: withUser, session: front, window: window, focus: focus.probe)
        }
    }

    private func typePick(_ item: OnePassword.Item, withUser: Bool, session: NSRunningApplication, window: WindowUnderPointer?,
                          focus: FocusProbe) {
        Task { @MainActor in
            let password: String, username: String
            do {
                password = try await OnePassword.field("password", of: item.id)
                username = withUser ? try await OnePassword.field("username", of: item.id) : ""
            } catch let failure as OnePassword.Failure {
                Toast.show(failure.message, seconds: 4)
                return
            } catch {
                Toast.show("1Password could not be read", seconds: 3)
                return
            }
            guard !password.isEmpty else { Toast.show("That item has no password", seconds: 2.5); return }
            guard !withUser || !username.isEmpty else { Toast.show("That item has no username. Press Return for the password only", seconds: 3); return }
            guard !session.isTerminated else { Toast.show("The ScreenConnect session closed. Nothing was typed", seconds: 3); return }
            // Back to the very session window the key was pressed over.
            if let window { Paster.raise(pid: session.processIdentifier, window: window) }
            Paster.bringBack(session)
            for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != session.processIdentifier {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(200))   // the session takes the keyboard back
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.processIdentifier, focus.stillFocused() else {
                Toast.show("The ScreenConnect session did not come back to the front. Nothing was typed", seconds: 3)
                return
            }
            if TextTyper.capsLockOn { Toast.show("Caps Lock is on. Turn it off and press Password again", seconds: 3); return }
            guard !typing, let (plan, options) = typingPlan(withUser ? username + "\t" + password : password), !plan.keys.isEmpty else { return }
            SpeedyShared.log.notice("1Password: typing a pick into the session\(withUser ? " (username and password)" : "", privacy: .public)")
            start(plan: plan, options: options, focus: focus, releaseKey: CGKeyCode(kVK_Return))
        }
    }

    // MARK: typing

    /// `releaseKey`: the key that started this (the shortcut's, or Return in the 1Password search), which has to be
    /// up before anything is typed.
    private func start(plan: TypingPlan, options: TypingOptions, focus: FocusProbe, releaseKey: CGKeyCode? = nil) {
        typing = true
        targetPID = focus.pid
        cancelled.set(false)
        sessionInFront.set(true)
        escKey?.register()
        state.typing = true
        SpeedyShared.log.notice("typing started")   // no lengths: the clipboard is often a password

        let cancelled = self.cancelled, sessionInFront = self.sessionInFront, hotKeyCode = releaseKey ?? self.hotKeyCode
        DispatchQueue.global(qos: .userInitiated).async {
            // The remote has already seen the real Cmd and Shift go down. Typing before they come back up
            // would turn every letter into a Windows-key shortcut on the other end.
            let wait = TextTyper.waitForPhysicalRelease(key: hotKeyCode, timeout: 3.0)
            let released = wait.released
            SpeedyShared.log.notice("typing wait: \(wait.waitedMs) ms, keyboard held keys=\(wait.sawHardware), software-only=\(wait.sawSoftwareOnly)")
            var posted = 0
            if released {
                usleep(120_000)   // let the key-ups reach the remote first
                posted = TextTyper.post(plan, options: options) {
                    cancelled.get() || !sessionInFront.get() || TextTyper.physicalCommandKeysDown() || !focus.stillFocused()
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(released: released, posted: posted, total: plan.keys.count)
                }
            }
        }
    }

    private func finish(released: Bool, posted: Int, total: Int) {
        typing = false
        state.typing = false
        escKey?.unregister()
        let outcome = !released ? "modifiers still held" : posted < total ? "stopped early" : "complete"
        SpeedyShared.log.notice("typing finished: \(outcome, privacy: .public)")
        if !released {
            Toast.show("Let go of the keys, then press \(state.typingShortcutLabel) again", seconds: 3)
        } else if posted < total {
            Toast.show("Typing stopped", seconds: 2)
        }
    }
}
