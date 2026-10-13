import AppKit
import Carbon.HIToolbox

/// A ScreenConnect session window open on this Mac.
struct SessionWindow: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    /// "ScreenConnect - FLC-JACKSON - Connected" (the app's name when window titles cannot be read).
    let title: String
    let bounds: CGRect
    var id: CGWindowID { windowID }

    /// The title's shape: "ScreenConnect - <name> - <state>", where the state is Connected, Stopped, Disconnected…
    private var titleParts: [String]? {
        let parts = title.components(separatedBy: " - ")
        return parts.count >= 3 && parts[0].lowercased().contains("screenconnect") ? parts : nil
    }

    /// "FLC-JACKSON" out of the title; the whole title when it has another shape.
    var name: String { titleParts.map { $0.dropFirst().dropLast().joined(separator: " - ") } ?? title }

    /// "Connected", "Stopped"… or nil when the title does not say.
    var state: String? { titleParts?.last }

    /// A session the remote machine is listening to. Unknown counts as yes (titles unreadable without Screen Recording).
    var connected: Bool { state.map { $0.caseInsensitiveCompare("Connected") == .orderedSame } ?? true }

    /// "FLC-JACKSON (stopped)" for the picker.
    var label: String { connected ? name : "\(name) (\(state?.lowercased() ?? "not connected"))" }
}

enum SessionWindows {
    /// Every session window, front to back: the big ordinary windows of the ScreenConnect client processes,
    /// without their Chat and Status windows. Titles need Screen Recording; without it the app name is used,
    /// and the size limit is what keeps the small Chat and Status windows out.
    @MainActor static func all() -> [SessionWindow] {
        let apps = NSWorkspace.shared.runningApplications.filter(FrontmostAppGate.isScreenConnect)
        guard !apps.isEmpty else { return [] }
        var names: [pid_t: String] = [:]
        for a in apps { names[a.processIdentifier] = a.localizedName ?? "ScreenConnect" }
        // Windows on this desktop first; a session parked on another desktop counts too.
        let passes: [CGWindowListOption] = [[.optionOnScreenOnly, .excludeDesktopElements], [.optionAll, .excludeDesktopElements]]
        for options in passes {
            guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
            var out: [SessionWindow] = []
            for d in raw {
                guard let pid = d[kCGWindowOwnerPID as String] as? pid_t, let appName = names[pid],
                      (d[kCGWindowLayer as String] as? Int) == 0,
                      let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                      r.width >= 400, r.height >= 300,
                      let id = d[kCGWindowNumber as String] as? CGWindowID else { continue }
                let name = d[kCGWindowName as String] as? String ?? ""
                if name.hasPrefix("Chat - ") || name.hasPrefix("Status - ") { continue }
                if out.contains(where: { $0.windowID == id }) { continue }
                out.append(SessionWindow(pid: pid, windowID: id, title: name.isEmpty ? appName : name, bounds: r))
            }
            // The client also keeps small untitled helper windows; when the real session windows can be told
            // apart by their title, only those count.
            let titled = out.filter { $0.title.hasPrefix("ScreenConnect - ") }
            if !titled.isEmpty { return titled }
            if !out.isEmpty { return out }
        }
        return []
    }
}

/// Types commands into a ScreenConnect session from a button in this app: brings the session window to the
/// front, then plays a list of steps (shortcuts, text, single keys, pauses) key by key, the way ⇧⌘V types.
/// Esc stops it, as does switching away from the session or the session's chat window taking focus.
@MainActor
final class RemoteShell {
    enum Step: Sendable {
        /// A shortcut on a letter key. Cmd reaches a Windows session as the Windows key, so
        /// `.chord("r", command: true, shift: false)` is Win+R there.
        case chord(Character, command: Bool, shift: Bool)
        case text(String)
        case key(CGKeyCode)
        case wait(ms: Int)
    }

    struct Group: Sendable {
        let label: String
        let steps: [Step]
    }

    enum Outcome: Sendable, Equatable {
        case done
        case noPermission
        case sessionGone
        case notInFront
        case chatWindow
        case capsLock
        case untypeable(String)
        case modifiersHeld
        case stopped(String)
    }

    private enum PreparedStep: Sendable {
        case chord(CGKeyCode, command: Bool, shift: Bool)
        case text(TypingPlan)
        case key(CGKeyCode)
        case wait(Int)
    }

    private(set) var running = false
    private var escKey: GlobalHotKey?
    private var activation: NSObjectProtocol?
    private let cancelled = AtomicFlag()
    private let inFront = AtomicFlag()
    private var targetPID: pid_t = 0

    func cancel() { cancelled.set(true) }

    func run(_ groups: [Group], in session: SessionWindow, pace: TypingOptions,
             progress: @escaping @MainActor @Sendable (String) -> Void,
             completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        guard !running else { return }
        guard Permissions.accessibilityTrusted, Permissions.canPostEvents else { completion(.noPermission); return }
        guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else { completion(.sessionGone); return }
        guard let keyMap = LayoutKeyMap.current() else { completion(.stopped("Could not read this Mac's keyboard layout")); return }
        if TextTyper.capsLockOn { completion(.capsLock); return }

        // Everything is checked for typeability before a single key goes out: a command with one character
        // missing is a different command.
        let options = pace
        var prepared: [(label: String, steps: [PreparedStep])] = []
        for g in groups {
            var steps: [PreparedStep] = []
            for s in g.steps {
                switch s {
                case .chord(let ch, let command, let shift):
                    guard let ks = keyMap.map[ch] else { completion(.untypeable(String(ch))); return }
                    steps.append(.chord(ks.keyCode, command: command, shift: shift || ks.shift))
                case .text(let t):
                    let plan = TextTyper.plan(t, keyMap: keyMap, options: options)
                    guard plan.skipped.isEmpty else {
                        var seen = Set<Character>()
                        completion(.untypeable(String(plan.skipped.filter { seen.insert($0).inserted }.prefix(8))))
                        return
                    }
                    steps.append(.text(plan))
                case .key(let code): steps.append(.key(code))
                case .wait(let ms): steps.append(.wait(ms))
                }
            }
            prepared.append((g.label, steps))
        }

        running = true
        targetPID = session.pid
        cancelled.set(false)
        progress("Bringing \(session.name) to the front…")
        let work = prepared
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.bringToFront(app, window: session) else { self.finish(.notInFront, completion: completion); return }
            let focus = FocusProbe.capture(pid: session.pid)
            if FocusProbe.isChatOrStatus(focus.title) { self.finish(.chatWindow, completion: completion); return }
            self.inFront.set(true)
            if self.escKey == nil {
                self.escKey = GlobalHotKey(keyCode: kVK_Escape, carbonModifiers: 0) { [weak self] in self?.cancelled.set(true) }
            }
            self.escKey?.register()
            self.activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFront.set(NSWorkspace.shared.frontmostApplication?.processIdentifier == self.targetPID)
                }
            }
            let cancelled = self.cancelled, inFront = self.inFront, probe = focus.probe
            SpeedyShared.log.notice("remote shell: \(work.count) step group(s) into a session")
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Self.play(work, options: options, probe: probe, cancelled: cancelled, inFront: inFront) { label in
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress(label) } }
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(outcome, completion: completion) } }
            }
        }
    }

    private func finish(_ outcome: Outcome, completion: @MainActor (Outcome) -> Void) {
        running = false
        escKey?.unregister()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        SpeedyShared.log.notice("remote shell finished: \(String(describing: outcome), privacy: .public)")
        completion(outcome)
    }

    /// Raises the session window and waits until its app is frontmost (up to 3 s), then a moment more for the
    /// window to take keyboard focus.
    private func bringToFront(_ app: NSRunningApplication, window: SessionWindow) async -> Bool {
        let pid = app.processIdentifier
        let target = WindowUnderPointer(windowID: window.windowID, ownerPID: pid, ownerName: "", bounds: window.bounds)
        let already = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && WindowHitTest.frontWindow(ofPID: pid)?.windowID == window.windowID
        if !already { Paster.raise(pid: pid, window: target) }
        let clock = ContinuousClock()
        let start = clock.now
        var triedWorkspace = false
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if clock.now - start > .seconds(3) { return false }
            if !triedWorkspace, clock.now - start > .milliseconds(300) { triedWorkspace = true; Paster.activateViaWorkspace(app) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(already ? 150 : 400))
        return true
    }

    nonisolated private static func play(_ groups: [(label: String, steps: [PreparedStep])], options: TypingOptions, probe: FocusProbe,
                                         cancelled: AtomicFlag, inFront: AtomicFlag,
                                         progress: @escaping @Sendable (String) -> Void) -> Outcome {
        // The click that started this may have come with a key still down (Return on the button, a modifier):
        // the remote must see nothing until every key is up.
        guard TextTyper.waitForPhysicalRelease(key: CGKeyCode(kVK_Return), timeout: 3).released else { return .modifiersHeld }
        usleep(120_000)
        let source = TextTyper.makeSource()
        func blocked() -> String? {
            if cancelled.get() { return "Stopped" }
            if !inFront.get() { return "Stopped: the session is no longer in front" }
            if TextTyper.physicalCommandKeysDown() { return "Stopped: a modifier key was pressed" }
            if !probe.stillFocused() { return "Stopped: another ScreenConnect window took focus" }
            return nil
        }
        for g in groups {
            progress(g.label)
            for step in g.steps {
                if let why = blocked() { return .stopped(why) }
                switch step {
                case .chord(let code, let command, let shift):
                    TextTyper.postChord(code, command: command, shift: shift, source: source)
                case .text(let plan):
                    let posted = TextTyper.post(plan, options: options) { blocked() != nil }
                    if posted < plan.keys.count { return .stopped(blocked() ?? "Stopped") }
                case .key(let code):
                    TextTyper.postKey(code, source: source)
                case .wait(let ms):
                    var left = ms
                    while left > 0 {
                        if let why = blocked() { return .stopped(why) }
                        let slice = min(left, 50)
                        usleep(UInt32(slice) * 1000)
                        left -= slice
                    }
                }
                usleep(options.interKeyMicros)
            }
        }
        return .done
    }
}
