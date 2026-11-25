import AppKit
import SwiftUI

/// 1Password on this Mac, through its command-line tool `op` with the 1Password app's CLI integration on (the app
/// asks for Touch ID or the account password; Speedy Bot never sees or stores that). Only item titles, usernames,
/// vaults and websites are listed; a password is fetched only for the item the tech picks, held in memory just long
/// enough to type it, and never logged, written or put on the clipboard.
enum OnePassword {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let username: String
        let vault: String
        let urls: [String]
    }

    enum Failure: Error {
        case notInstalled, integrationOff(String), cancelled, failed(String)

        /// For the log: which failure, never the tool's own words.
        var kind: String {
            switch self {
            case .notInstalled: return "not installed"
            case .integrationOff: return "CLI integration off or app not reachable"
            case .cancelled: return "not unlocked / cancelled"
            case .failed: return "failed"
            }
        }

        var message: String {
            switch self {
            case .notInstalled: return "The 1Password command-line tool is not installed (brew install --cask 1password-cli)"
            case .integrationOff: return "Speedy Bot could not reach the 1Password app. Open 1Password and check Settings > Developer > Integrate with 1Password CLI"
            case .cancelled: return "1Password was not unlocked"
            case .failed(let why): return "1Password: \(why)"
            }
        }
    }

    static var cliPath: String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Logins, passwords, servers and databases across every vault the account can see.
    static func list() async throws -> [Item] {
        let out = try await run(["item", "list", "--categories", "Login,Password,Server,Database", "--format", "json"])
        guard let rows = try? JSONSerialization.jsonObject(with: out) as? [[String: Any]] else { throw Failure.failed("unexpected answer") }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let vault = (row["vault"] as? [String: Any])?["name"] as? String ?? ""
            let urls = (row["urls"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
            return Item(id: id, title: row["title"] as? String ?? "(untitled)",
                        username: row["additional_information"] as? String ?? "", vault: vault, urls: urls)
        }
    }

    struct Secrets: Sendable { let username: String; let password: String }

    /// The username and password of one item, exactly as stored (read from the item's JSON, not from `--fields`,
    /// whose CSV output quotes a value with a comma or a quote in it). The item's own password field (purpose
    /// PASSWORD, or the field with id "password") is used; an item with no such field but exactly one field labelled
    /// "password" uses that one, and one with several is refused rather than guessed.
    static func secrets(of id: String) async throws -> Secrets {
        let out = try await run(["item", "get", id, "--format", "json", "--reveal"])
        guard let item = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { throw Failure.failed("unexpected answer") }
        let fields = item["fields"] as? [[String: Any]] ?? []
        func pick(purpose: String, id: String) throws -> String {
            if let f = fields.first(where: { ($0["purpose"] as? String) == purpose }) ?? fields.first(where: { ($0["id"] as? String) == id }) {
                return f["value"] as? String ?? ""
            }
            let labelled = fields.filter { ($0["label"] as? String)?.lowercased() == id }
            if labelled.count > 1 { throw Failure.failed("that item has more than one \(id) field") }
            return labelled.first?["value"] as? String ?? ""
        }
        return Secrets(username: try pick(purpose: "USERNAME", id: "username"), password: try pick(purpose: "PASSWORD", id: "password"))
    }

    /// Runs `op` off the main thread. Its output is returned, never logged; its error text is matched, and its first
    /// line logged (op's own error words, e.g. "connecting to desktop app"; secrets only ever come on its output).
    private static func run(_ arguments: [String]) async throws -> Data {
        guard let path = cliPath else { throw Failure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let result = execute(path, arguments, disclaim: true) else {
                    continuation.resume(throwing: Failure.failed("could not start the command-line tool"))
                    return
                }
                if result.status == 0 {
                    continuation.resume(returning: result.out)
                    return
                }
                let text = String(decoding: result.err, as: UTF8.self)
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                SpeedyShared.log.notice("1Password command failed (status \(result.status, privacy: .public)): \(String(firstLine.prefix(200)), privacy: .public)")
                continuation.resume(throwing: classify(text))
            }
        }
    }

    /// What op's error text means for the tech.
    static func classify(_ errorText: String) -> Failure {
        let message = errorText.lowercased()
        if message.contains("integration") || message.contains("no accounts configured") || message.contains("connecting to desktop app")
            || message.contains("app is not running") || message.contains("operation not permitted")
            || message.contains("no account found") {   // what a blocked op says: it cannot see the app's accounts
            return .integrationOff(message)
        }
        if message.contains("cancel") || message.contains("dismissed") || message.contains("authorization") {
            return .cancelled
        }
        return .failed("the command-line tool could not answer")
    }

    /// `responsibility_spawnattrs_setdisclaim` (in libSystem since macOS 10.14; Terminal-style apps, LLDB and
    /// Chromium use it). Without it macOS counts `op` as Speedy Bot itself, and then refuses it 1Password's own data
    /// folder, where the socket to the 1Password app lives ("Speedy Bot reading another app's data": denied with no
    /// prompt). Disclaimed, `op` answers for itself, and it is made by the same developer as the 1Password app.
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: SetDisclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    /// Starts `path` with `arguments` (stdin empty, no other open files passed on, signals as new), reads its output
    /// and error text to the end and waits for it. nil: it could not be started.
    static func execute(_ path: String, _ arguments: [String], disclaim: Bool) -> (status: Int32, out: Data, err: Data)? {
        let outPipe = Pipe(), errPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.fileHandleForWriting.fileDescriptor, 2)
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // Only stdin/out/err reach op (CLOEXEC_DEFAULT closes every other descriptor Speedy Bot has open).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        if disclaim, let setDisclaim { _ = setDisclaim(&attributes, 1) }

        var environment = ProcessInfo.processInfo.environment
        environment["OP_FORMAT"] = nil
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        // The parent's copies of the write ends must go, or reading to the end never ends.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        guard spawned == 0 else {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return nil
        }
        // Read both pipes while it runs (a big vault list fills a pipe's buffer).
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()   // the reader is done before its data is used
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        // Exited normally: its exit code; killed by a signal: 128 + the signal, as a shell reports it.
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (code, outBox.data, errData)
    }

    /// For `--check-1password`: can `op` reach the 1Password app when started by Speedy Bot, the old way (counted as
    /// Speedy Bot) and the way Speedy Bot uses (answering for itself)? `op whoami` asks for no unlock.
    static func connectionReport() -> [String] {
        guard let path = cliPath else { return ["op is not installed"] }
        return [false, true].map { disclaim in
            let name = disclaim ? "op on its own (used)" : "op as Speedy Bot (old)"
            guard let r = execute(path, ["whoami"], disclaim: disclaim) else { return "\(name): could not start" }
            let err = String(decoding: r.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reached = r.status == 0 || err.lowercased().contains("not signed in")
            return "\(name): \(reached ? "REACHES the 1Password app" : "CANNOT reach the 1Password app") (status \(r.status)) \(err.prefix(160))"
        }
    }

    /// Words in a ScreenConnect window title that say nothing about the machine (the tech's own ScreenConnect login
    /// must never come first because of them).
    static let titleNoise: Set<String> = ["screenconnect", "connectwise", "control", "connected", "connecting", "disconnected",
                                          "session", "sessions", "remote", "access", "support", "meeting", "guest", "host", "client", "the"]

    /// Items whose title or website shares a word (3+ letters, not ScreenConnect's own) with the session's name come
    /// first, then A-Z. `matched`: whether the first one shares such a word (only then is it chosen in advance).
    static func ranked(_ items: [Item], session: String) -> (items: [Item], matched: Bool) {
        let words = Set(session.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !titleNoise.contains($0) })
        func score(_ item: Item) -> Int {
            let hay = (item.title + " " + item.urls.joined(separator: " ")).lowercased()
            return words.filter { hay.contains($0) }.count
        }
        let sorted = items.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return (sorted, sorted.first.map { score($0) > 0 } ?? false)
    }
}

/// A panel that can take the keyboard (and the search box's typing) while another app stays in front.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The search box over the 1Password vault that the keypad's Password key opens over a ScreenConnect session.
/// Return types the password into the session; Option-Return types the username, Tab, then the password. Esc closes.
@MainActor
final class PasswordPicker: NSObject, NSWindowDelegate {
    final class Model: ObservableObject {
        @Published var items: [OnePassword.Item] = []
        @Published var query = ""
        @Published var selection: OnePassword.Item.ID?
        @Published var status: String? = "Waiting for 1Password…"
        let session: String

        init(session: String) { self.session = session }

        var shown: [OnePassword.Item] {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return items }
            return items.filter { item in
                [item.title, item.username, item.vault, item.urls.joined(separator: " ")].contains { $0.lowercased().contains(q) }
            }
        }
    }

    private var panel: NSPanel?
    private var model: Model?
    private var keyMonitor: Any?
    /// What a pick does: (item, with username).
    private var onPick: ((OnePassword.Item, Bool) -> Void)?

    /// `over`: the session window's frame (AppKit coordinates), to open the box over it.
    func show(session: String, over: NSRect? = nil, onPick: @escaping (OnePassword.Item, Bool) -> Void) {
        close()
        let model = Model(session: session)
        self.model = model
        self.onPick = onPick
        let view = PasswordPickerView(model: model, pick: { [weak self] item, withUser in self?.pick(item, withUser: withUser) })
        // A key press from the keypad is not a click in Speedy Bot, so macOS will not bring Speedy Bot to the front
        // for it. The search box is therefore a panel that takes the keyboard without Speedy Bot coming to the front,
        // and stays up while another app is in front (a plain panel hides itself then: the box opened unseen).
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Type a 1Password password"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]   // over a full-screen session too
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: view)
        if let frame = over, let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            // Centred on the session window (given in AppKit's bottom-left coordinates), kept on its screen.
            let visible = screen.visibleFrame
            var origin = NSPoint(x: frame.midX - 260, y: frame.midY - 210)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - 520)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - 420)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
            MainActor.assumeIsolated {
                guard let panel, panel.isVisible else { return }
                SpeedyShared.log.notice("1Password: picker \(panel.isKeyWindow ? "has" : "does not have", privacy: .public) the keyboard")
                if !panel.isKeyWindow { Toast.show("Click the 1Password search box, then type", seconds: 2.5) }
            }
        }
        // Arrows move the selection and Esc closes, wherever the keyboard is in the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, let model = self.model else { return event }
            switch Int(event.keyCode) {
            case 53: self.close(); return nil   // Esc
            case 125, 126:                       // down, up
                let list = model.shown
                guard !list.isEmpty else { return nil }
                let i = list.firstIndex { $0.id == model.selection } ?? -1
                let next = event.keyCode == 125 ? min(i + 1, list.count - 1) : max(i - 1, 0)
                model.selection = list[next].id
                return nil
            case 36, 76:                         // Return, Enter
                let withUser = event.modifierFlags.contains(.option)
                // A click on a row selects it a moment later: let that land before reading the selection.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        guard self.model === model else { return }
                        let list = model.shown
                        let searched = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
                        if let item = list.first(where: { $0.id == model.selection }) ?? (searched ? list.first : nil) {
                            self.pick(item, withUser: withUser)
                        } else {
                            NSSound.beep()   // nothing chosen yet
                        }
                    }
                }
                return nil
            default: return event
            }
        }
        Task { @MainActor in
            do {
                let ranked = OnePassword.ranked(try await OnePassword.list(), session: session)
                SpeedyShared.log.notice("1Password: \(ranked.items.count, privacy: .public) items listed\(ranked.matched ? ", one matches the session" : "", privacy: .public)")
                guard self.model === model else { return }
                model.items = ranked.items
                // Chosen in advance only when it matches this session; otherwise the tech picks or searches.
                model.selection = ranked.matched ? ranked.items.first?.id : nil
                model.status = ranked.items.isEmpty ? "No logins in 1Password" : nil
            } catch let failure as OnePassword.Failure {
                SpeedyShared.log.notice("1Password: list failed: \(failure.kind, privacy: .public)")
                guard self.model === model else { return }
                model.status = failure.message
            } catch {
                SpeedyShared.log.notice("1Password: list failed")
                model.status = "1Password could not be read"
            }
        }
    }

    private func pick(_ item: OnePassword.Item, withUser: Bool) {
        let onPick = self.onPick
        close()
        onPick?(item, withUser)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        model = nil
        onPick = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel = nil
        model = nil
        onPick = nil
    }
}

private struct PasswordPickerView: View {
    @ObservedObject var model: PasswordPicker.Model
    let pick: (OnePassword.Item, Bool) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search 1Password", text: $model.query)
                .textFieldStyle(.roundedBorder).font(.title3)
                .focused($searchFocused)
                .onChange(of: model.query) { _ in
                    // Typing a search chooses its first result; clearing it chooses nothing.
                    model.selection = model.query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.shown.first?.id
                }
            if let status = model.status {
                Text(status).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(model.shown, selection: $model.selection) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.medium))
                            Text([item.username, item.vault].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { pick(item, NSEvent.modifierFlags.contains(.option)) }
                    }
                    .onChange(of: model.selection) { id in if let id { proxy.scrollTo(id) } }
                }
            }
            Text("Return types the password into \(model.session.isEmpty ? "the session" : model.session).  ⌥Return types the username, Tab, then the password.  Esc closes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 14)
        .onAppear { searchFocused = true }
    }
}
