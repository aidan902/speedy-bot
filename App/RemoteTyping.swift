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
    /// ⌃Space (or the tech's own): the keypad's Password key from the keyboard, claimed only while a session is in front.
    private var passwordGate: FrontmostAppGate?
    private var passwordSpec: HotKeySpec?
    /// The shortcut was pressed; the search opens once its keys are up.
    private var waitingForPasswordKeys = false
    private var hotKeyCode = CGKeyCode(kVK_ANSI_V)
    private var hotKeyModifiers = cmdKey | shiftKey
    private var escKey: GlobalHotKey?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    /// The Password key: Speedy Bot is not Off and typing is on. Unlike `enabled`, no session has to be open (it
    /// also types on .fm sites on this Mac).
    private var passwordEnabled = false
    /// A 1Password pick for a page on this Mac is being fetched or typed: a session closing does not stop it.
    private var localRun = false

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
            passwordGate?.enabled = true
        } else {
            gate?.enabled = false
            passwordGate?.enabled = false
            if !(localRun && passwordEnabled) { cancelled.set(true) }
            pendingConfirm = nil
        }
    }

    func setPasswordEnabled(_ on: Bool) {
        passwordEnabled = on
        if on {
            if gate == nil { build() }   // Esc and the front-app watch; the session shortcuts still follow `enabled`
        } else {
            cancelled.set(true)          // Off, or typing switched off: nothing more is typed anywhere
            picker.close()
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
            MainActor.assumeIsolated { self?.registerHotKey(); self?.registerPasswordHotKey() }
        })
        registerPasswordHotKey()
    }

    /// (Re)creates the Password shortcut: the tech's own, or ⌃Space. Not claimed
    /// at all when another of Speedy Bot's jobs already has that combination (a shortcut recorded before this one
    /// existed).
    private func registerPasswordHotKey() {
        let spec = state.passwordShortcut ?? HotKeySpec.defaultPassword
        if passwordGate != nil, spec == passwordSpec { return }
        passwordGate?.stop()
        passwordGate = nil
        passwordSpec = spec
        if let job = state.owner(of: spec, except: .password) {
            SpeedyShared.log.notice("password shortcut \(spec.label, privacy: .public) not claimed: it is the shortcut for \(job, privacy: .public)")
            return
        }
        let hk = GlobalHotKey(keyCode: spec.keyCode, carbonModifiers: spec.carbonModifiers) { [weak self] in self?.passwordFromShortcut() }
        let g = FrontmostAppGate(hotKey: hk, matches: FrontmostAppGate.isScreenConnect)
        g.enabled = enabled
        passwordGate = g
    }

    /// The Password shortcut. ScreenConnect has already passed its modifiers to the remote (⌃ as Ctrl, ⌘ as the
    /// Windows key, ⇧ as Shift). The search would take the keyboard, so their key-ups would never reach the remote and
    /// Windows would keep them held: the next keys typed there would be Ctrl or Windows-key shortcuts. So the search
    /// opens only once every key of the shortcut is up and the session has passed that on.
    private func passwordFromShortcut() {
        guard enabled, !typing, !pickInFlight, !openingPicker, !waitingForPasswordKeys else { return }
        waitingForPasswordKeys = true
        let key = CGKeyCode(passwordSpec?.keyCode ?? Int(kVK_Space))
        let label = state.passwordShortcutLabel
        DispatchQueue.global(qos: .userInitiated).async {
            let wait = TextTyper.waitForPhysicalRelease(key: key, timeout: 3.0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.waitingForPasswordKeys = false
                    guard wait.released else { Toast.show("Let go of the keys, then press \(label) again", seconds: 3); return }
                    self.passwordFromKey()
                }
            }
        }
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
        if gate != nil { registerHotKey(); registerPasswordHotKey() }
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
        // The 1Password search can hold the keyboard while the session stays the app in front: the clipboard would be
        // typed into the search (and a line break in it could pick a login), and no front-app check here can see that.
        guard !picker.isOpen else {
            Toast.show("Close the 1Password search first (Esc), then press \(state.typingShortcutLabel) again", seconds: 3)
            return
        }
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
    /// `secret`: a password from 1Password. Typed exactly (no curly quote or dash turned into a plain one), and the
    /// characters that cannot be typed are never shown.
    private func typingPlan(_ text: String, secret: Bool = false) -> (TypingPlan, TypingOptions)? {
        guard let keyMap = LayoutKeyMap.current() else {
            Toast.show("Could not read this Mac's keyboard layout")
            return nil
        }
        var options = state.fastTyping ? TypingOptions.fast : TypingOptions()
        if secret { options.asciiFold = false }
        let plan = TextTyper.plan(text, keyMap: keyMap, options: options)
        guard plan.skipped.isEmpty else {
            var seen = Set<Character>()
            let sample = String(plan.skipped.filter { seen.insert($0).inserted }.prefix(8))
            Toast.show(secret ? "This password has characters this keyboard layout cannot type. Nothing was typed"
                              : "This keyboard cannot type: \(sample)  Nothing was typed", seconds: 4)
            SpeedyShared.log.notice("typing refused: characters not on this keyboard layout")
            return nil
        }
        return (plan, options)
    }

    // MARK: 1Password

    private lazy var picker = PasswordPicker()
    /// A pick is being fetched and the session brought back: Esc (or switching Speedy Bot off) still stops it.
    private var pickInFlight = false
    /// What a "let go of the keys" note tells the tech to press again.
    private var retryLabel = ""

    /// Where a 1Password pick is typed: a ScreenConnect session window, or a page on a .fm site in a browser on this Mac.
    private struct PasswordTarget {
        let app: NSRunningApplication
        let window: WindowUnderPointer?
        let focus: FocusProbe
        /// "The ScreenConnect session" / "The browser", for the notes.
        let name: String
        /// On this Mac: the site the page was on when the key was pressed; nothing is typed once it is elsewhere.
        let pageHost: String?
    }

    /// The keypad's Password key (or the menu): a search over the local 1Password vault, opened over the ScreenConnect
    /// session in front, or over a browser on this Mac showing a .fm site. Logins saved for the page's site come first
    /// (the remote browser's address is read off the session window, this Mac's through accessibility). The pick is
    /// typed into that window key by key, never through the clipboard. Pressed again while the search is up, it
    /// types the chosen login.
    func passwordFromKey() {
        guard passwordEnabled else { Toast.show("Typing into ScreenConnect is switched off in Speedy Bot", seconds: 2.5); return }
        guard !typing, !pickInFlight, !openingPicker else { return }
        if picker.isOpen {
            if !picker.pickChosen() {
                Toast.show(picker.isWaiting ? "Wait for 1Password's list, then press Password again" : "Pick a login first, or type to search", seconds: 2)
            }
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        guard OnePassword.cliPath != nil else { Toast.show(OnePassword.Failure.notInstalled.message, seconds: 4); return }
        if FrontmostAppGate.isScreenConnect(front) {
            guard enabled else { Toast.show("Typing into ScreenConnect is switched off in Speedy Bot", seconds: 2.5); return }
            passwordForSession(front)
        } else if PasteTarget.isBrowser(front) {
            passwordForBrowser(front)
        } else {
            Toast.show("Click into a ScreenConnect session, or a .fm site in your browser, then press Password", seconds: 3)
        }
    }

    /// The browser page is read before the search opens (well under a second); a second press meanwhile is ignored.
    private var openingPicker = false

    /// AppKit's frame (bottom-left origin) of a window CG gave (top-left origin of the primary screen).
    private static func appKitFrame(_ w: WindowUnderPointer) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: w.bounds.minX, y: primaryHeight - w.bounds.maxY, width: w.bounds.width, height: w.bounds.height)
    }

    private func passwordForSession(_ front: NSRunningApplication) {
        let focus = FocusProbe.capture(pid: front.processIdentifier)
        if FocusProbe.isChatOrStatus(focus.title) {
            Toast.show("That is the ScreenConnect chat window. Click the remote screen first", seconds: 3)
            return
        }
        let window = WindowHitTest.frontWindow(ofPID: front.processIdentifier)
        SpeedyShared.log.notice("1Password: picker opened over the session")
        let windowID = window?.windowID
        let target = PasswordTarget(app: front, window: window, focus: focus.probe, name: "The ScreenConnect session", pageHost: nil)
        picker.show(place: focus.title ?? "the session", session: focus.title ?? "", over: window.map(Self.appKitFrame), hosts: {
            guard let windowID else { return [] }
            return await OnePassword.remotePageHosts(windowID: windowID)
        }) { [weak self] item, withUser in
            self?.typePick(item, withUser: withUser, target: target)
        }
    }

    /// On this Mac: only on a site with ".fm" in its name, and only into a field on the page (not the address bar).
    private func passwordForBrowser(_ front: NSRunningApplication) {
        let pid = front.processIdentifier
        openingPicker = true
        Task { @MainActor [weak self] in
            let page = await OnePassword.browserPage(pid: pid)
            guard let self else { return }
            self.openingPicker = false
            // The tech may have moved on while the page was read.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !self.picker.isOpen, !self.typing, !self.pickInFlight else { return }
            if page.inBrowserField {
                Toast.show("Click into the password field on the page first, then press Password", seconds: 3)
                return
            }
            guard let host = page.host else {
                Toast.show("Could not tell which page has the keyboard, so nothing was opened. Click into the password field and try again", seconds: 3.5)
                return
            }
            let title = WindowHitTest.frontWindow(ofPID: pid)?.title.lowercased() ?? ""
            if title.contains("screenconnect") || title.contains("connectwise control") {
                Toast.show("That is a ScreenConnect session in the browser. Use the ScreenConnect app for sessions", seconds: 3)
                return
            }
            guard OnePassword.typesLocally(onHost: host) else {
                Toast.show("On this Mac, Password types only on .fm sites (this is \(host))", seconds: 3)
                return
            }
            let focus = FocusProbe.capture(pid: pid)
            let window = WindowHitTest.frontWindow(ofPID: pid)
            SpeedyShared.log.notice("1Password: picker opened over a browser page on \(host, privacy: .public)")
            let target = PasswordTarget(app: front, window: window, focus: focus.probe, name: "The browser", pageHost: host)
            self.picker.show(place: "\(host) on this Mac", session: "", over: window.map(Self.appKitFrame), hosts: { [host] }) { [weak self] item, withUser in
                self?.typePick(item, withUser: withUser, target: target)
            }
        }
    }

    private func typePick(_ item: OnePassword.Item, withUser: Bool, target: PasswordTarget) {
        // From the pick on, Esc stops it (and is not passed on to the remote), as does switching Speedy Bot off.
        pickInFlight = true
        localRun = target.pageHost != nil
        cancelled.set(false)
        escKey?.register()
        let me = ProcessInfo.processInfo.processIdentifier
        let app = target.app, pid = target.app.processIdentifier
        Task { @MainActor in
            @MainActor func stop(_ note: String?) {
                self.pickInFlight = false
                self.localRun = false
                self.escKey?.unregister()
                if let note { Toast.show(note, seconds: 3) }
            }
            // A session pick needs session typing on; a pick for this Mac only needs Speedy Bot on (not Off).
            @MainActor func stoppedByTech() -> Bool {
                self.cancelled.get() || !(target.pageHost == nil ? self.enabled : self.passwordEnabled)
            }
            let secrets: OnePassword.Secrets
            do {
                secrets = try await OnePassword.secrets(of: item.id)
            } catch let failure as OnePassword.Failure {
                stop(failure.message)
                return
            } catch {
                stop("1Password could not be read")
                return
            }
            let password = secrets.password, username = withUser ? secrets.username : ""
            if stoppedByTech() { stop("Stopped. Nothing was typed"); return }
            guard !password.isEmpty else { stop("That item has no password"); return }
            guard !withUser || !username.isEmpty else { stop("That item has no username. Press Return for the password only"); return }
            guard !app.isTerminated else { stop("\(target.name) closed. Nothing was typed"); return }
            // Only from Speedy Bot's own search (just closed) or the target itself: if the tech has moved to another
            // app meanwhile, they are doing something else.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == me || front == pid else { stop("You moved to another app. Nothing was typed"); return }
            // Back to the very window the key was pressed over.
            if let window = target.window { Paster.raise(pid: pid, window: window) }
            Paster.bringBack(app)
            for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(200))   // the target takes the keyboard back
            if stoppedByTech() { stop("Stopped. Nothing was typed"); return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, target.focus.stillFocused() else {
                stop("\(target.name) did not come back to the front. Nothing was typed")
                return
            }
            // On this Mac: still the same site, and the keyboard on the page (a redirect or a click elsewhere meanwhile
            // must not get the password).
            if let expected = target.pageHost {
                let page = await OnePassword.browserPage(pid: pid)
                guard page.host == expected, !page.inBrowserField else { stop("The page changed. Nothing was typed"); return }
                if stoppedByTech() { stop("Stopped. Nothing was typed"); return }
            }
            if TextTyper.capsLockOn { stop("Caps Lock is on. Turn it off and press Password again"); return }
            guard !self.typing, let (plan, options) = self.typingPlan(withUser ? username + "\t" + password : password, secret: true),
                  !plan.keys.isEmpty else { stop(nil); return }
            SpeedyShared.log.notice("1Password: typing a pick into \(target.pageHost == nil ? "the session" : "the browser", privacy: .public)\(withUser ? " (username and password)" : "", privacy: .public)")
            self.pickInFlight = false
            self.start(plan: plan, options: options, focus: target.focus, releaseKey: CGKeyCode(kVK_Return), retry: "Password")
        }
    }

    // MARK: typing

    /// `releaseKey`: the key that started this (the shortcut's, or Return in the 1Password search), which has to be
    /// up before anything is typed.
    /// `retry`: what the "let go of the keys" note says to press again (the shortcut when nil).
    private func start(plan: TypingPlan, options: TypingOptions, focus: FocusProbe, releaseKey: CGKeyCode? = nil, retry: String? = nil) {
        typing = true
        targetPID = focus.pid
        retryLabel = retry ?? state.typingShortcutLabel
        // A 1Password pick has been stoppable since it was picked, and was checked just now; the shortcut starts fresh.
        if releaseKey == nil { cancelled.set(false) }
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
        localRun = false
        state.typing = false
        escKey?.unregister()
        let outcome = !released ? "modifiers still held" : posted < total ? "stopped early" : "complete"
        SpeedyShared.log.notice("typing finished: \(outcome, privacy: .public)")
        if !released {
            Toast.show("Let go of the keys, then press \(retryLabel) again", seconds: 3)
        } else if posted < total {
            Toast.show("Typing stopped", seconds: 2)
        }
    }
}
