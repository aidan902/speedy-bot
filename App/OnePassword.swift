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

    /// The order the search lists logins in. `hosts`: the sites the page may be on, most likely first (read off the
    /// remote browser's address bar, or this Mac's browser). The first of them that any login is saved for decides:
    /// logins for that very address first, then others for the same site, then logins whose title shares a word
    /// (3+ letters, not ScreenConnect's own) with the session's name, then A-Z.
    /// `matched`: the first one fits the page or the session (only then is it chosen in advance); `host`: the site it
    /// fits; `read`: the most likely site, whether or not any login is saved for it.
    static func ranked(_ items: [Item], session: String, hosts: [String] = []) -> (items: [Item], matched: Bool, host: String?, read: String?) {
        let words = Set(session.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !titleNoise.contains($0) })
        func wordScore(_ item: Item) -> Int {
            let hay = (item.title + " " + item.urls.joined(separator: " ")).lowercased()
            return words.filter { hay.contains($0) }.count
        }
        let host = hosts.first { h in items.contains { siteMatch($0, host: h) > 0 } }
        func score(_ item: Item) -> (Int, Int) { (host.map { siteMatch(item, host: $0) } ?? 0, wordScore(item)) }
        let scored = items.map { ($0, score($0)) }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
        }
        let top = sorted.first?.1 ?? (0, 0)
        return (sorted.map(\.0), top.0 > 0 || top.1 > 0, host, hosts.first)
    }

    // MARK: which site the page is on

    /// A web address's host, lower-case, without "www."; nil when it has none. It must have a dot: a search word
    /// typed into an address bar is not a site.
    static func host(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard var host = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host?.lowercased(),
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The part of a host one owner holds: "login.qsys.com" -> "qsys.com", "a.b.co.uk" -> "b.co.uk". A numeric
    /// address stays whole.
    static func siteDomain(_ host: String) -> String {
        if IPv4(host) != nil { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ltd", "plc"]
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// How well a login's saved websites fit a site: 2 the same address, 1 another part of the same site, 0 none.
    static func siteMatch(_ item: Item, host: String) -> Int {
        let site = siteDomain(host)
        var best = 0
        for url in item.urls {
            guard let h = self.host(of: url) else { continue }
            if h == host { return 2 }
            if siteDomain(h) == site { best = 1 }
        }
        return best
    }

    /// On this Mac the Password key types only on sites with ".fm" anywhere in their name, counting its start:
    /// fm.example.com, portal.fm.example.com, radio.fm.
    static func typesLocally(onHost host: String) -> Bool { ("." + host.lowercased()).contains(".fm") }

    /// Endings of file names, which read like web addresses ("report.pdf") but are not sites.
    private static let fileEndings: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "pdf", "txt", "log", "csv", "exe", "msi", "dll",
        "zip", "rar", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "json", "xml", "ps1", "bat", "cmd", "html", "htm", "php", "aspx",
        "cfg", "ini", "iso", "dmg", "pkg", "mp4", "mov", "mp3", "wav", "bak", "tmp", "sys", "lnk", "vbs", "reg"]
    private static let addressPattern = try! NSRegularExpression(pattern:
        #"(?i)(?<![@\w.-])(https?://)?((?:[a-z0-9-]+\.)+[a-z]{2,24}|\d{1,3}(?:\.\d{1,3}){3})(?::\d{1,5})?(/\S*)?(?![@\w])"#)

    /// The sites shown in lines of text read off a session window, most likely the remote browser's address bar
    /// first: a line that is nothing but the address (an address bar), then the higher up the better. E-mail
    /// addresses and file names are not sites. At most four.
    static func pageHosts(in lines: [SessionProbe.Line]) -> [String] {
        var found: [(host: String, whole: Bool, top: Double)] = []
        for line in lines {
            let text = line.text as NSString
            for m in addressPattern.matches(in: line.text, range: NSRange(location: 0, length: text.length)) {
                let token = text.substring(with: m.range)
                guard let host = host(of: token) else { continue }
                let hasScheme = m.range(at: 1).location != NSNotFound, hasPath = m.range(at: 3).location != NSNotFound
                if !hasScheme, !hasPath, IPv4(host) == nil, let last = host.split(separator: ".").last, fileEndings.contains(String(last)) { continue }
                if host.allSatisfy({ $0.isNumber || $0 == "." }), IPv4(host) == nil { continue }   // "2.42.0": a version, not a site
                // An address bar shows the address alone (maybe with "Not secure" or a lock read as a letter or two).
                let rest = text.replacingCharacters(in: m.range, with: "").lowercased().replacingOccurrences(of: "not secure", with: "")
                let whole = rest.filter { $0.isLetter || $0.isNumber }.count <= 2
                found.append((host, whole, line.top))
            }
        }
        var seen = Set<String>()
        return found.sorted { ($0.whole ? 0 : 1, $0.top) < ($1.whole ? 0 : 1, $1.top) }
            .map(\.host).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    /// The sites in a ScreenConnect session window, read off the screen (Screen Recording permission). [] when it
    /// cannot be read.
    static func remotePageHosts(windowID: CGWindowID) async -> [String] {
        guard let lines = await SessionProbe.screenLines(windowID: windowID) else { return [] }
        let hosts = pageHosts(in: lines)
        SpeedyShared.log.notice("1Password: remote page read as \(hosts.first ?? "no site", privacy: .public)")
        return hosts
    }

    /// The page in a browser's front window on this Mac, through accessibility (no waking needed; well under a
    /// second): the window's document, else the page's own address, else the address bar's text.
    /// `inAddressBar`: the keyboard is in the address bar itself, so no field on the page is chosen.
    static func browserPage(pid: pid_t) async -> (host: String?, inAddressBar: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readBrowserPage(pid: pid))
            }
        }
    }

    private static func readBrowserPage(pid: pid_t) -> (host: String?, inAddressBar: Bool) {
        func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func element(_ v: AnyObject?) -> AXUIElement? {
            guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = element(attr(app, kAXFocusedWindowAttribute)) else { return (nil, false) }
        let focused = element(attr(app, kAXFocusedUIElementAttribute))
        let document = (attr(window, "AXDocument") as? String).flatMap(host(of:))
        var pageURL: String?
        var bar: AXUIElement?
        var queue = [window]
        var seen = 0
        let started = Date()
        while !queue.isEmpty, seen < 800, Date().timeIntervalSince(started) < 1.5, pageURL == nil || bar == nil {
            let e = queue.removeFirst()
            seen += 1
            AXUIElementSetMessagingTimeout(e, 0.3)
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" {
                if pageURL == nil, let url = attr(e, "AXURL") as? URL { pageURL = url.absoluteString }
                continue   // never into the page itself
            }
            if bar == nil, role == "AXTextField" || role == "AXComboBox" {
                let id = attr(e, kAXIdentifierAttribute) as? String ?? ""
                let label = ((attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? "").lowercased()
                if id == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" || label.contains("address") { bar = e; continue }
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        let inBar = bar.map { b in focused.map { CFEqual($0, b) } ?? false } ?? false
        let barHost = inBar ? nil : bar.flatMap { attr($0, kAXValueAttribute) as? String }.flatMap(host(of:))
        return (document ?? pageURL.flatMap(host(of:)) ?? barHost, inBar)
    }
}

/// True for the first caller only (whichever of two racing tasks gets there first).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
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
        /// Which site the list was matched to (or that nothing in 1Password is saved for the site read).
        @Published var note: String?
        /// Typed keys go into the search (false: they go to the app in front, e.g. after 1Password's Touch ID prompt).
        @Published var hasKeyboard = true
        /// Where the pick is typed, in the caption ("ScreenConnect - Front Desk - Connected", "portal.fm.example.com on this Mac").
        let place: String

        init(place: String) { self.place = place }

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
    /// Return was pressed; its pick waits for the key to come up.
    private var returnPending = false
    /// What a pick does: (item, with username).
    private var onPick: ((OnePassword.Item, Bool) -> Void)?

    /// The search is up. It can hold the keyboard while ScreenConnect (or the browser) stays the app in front, so
    /// nothing that checks the front app can tell where typed keys go meanwhile.
    var isOpen: Bool { panel != nil }

    /// `place`: where the pick is typed, for the caption. `session`: the ScreenConnect window's name, whose words
    /// rank logins. `over`: the target window's frame (AppKit coordinates), to open the box over it. `hosts`: the
    /// sites the page may be on, most likely first, read while 1Password lists its logins.
    func show(place: String, session: String, over: NSRect? = nil, hosts: @escaping @Sendable () async -> [String],
              onPick: @escaping (OnePassword.Item, Bool) -> Void) {
        close()
        let model = Model(place: place)
        self.model = model
        self.onPick = onPick
        let view = PasswordPickerView(model: model, pick: { [weak self] item, withUser in self?.pick(item, withUser: withUser) },
                                      takeKeyboard: { [weak self] in self?.takeKeyboard() })
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
        // The screen holding most of the target window (as AppKit decides a window's screen).
        var screen = NSScreen.main
        if let frame = over {
            var most: CGFloat = 0
            for candidate in NSScreen.screens {
                let shared = candidate.frame.intersection(frame)
                let area: CGFloat = shared.isNull ? 0 : shared.width * shared.height
                if area > most { most = area; screen = candidate }
            }
        }
        if let frame = over, let screen {
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
                // Repeats of a held Return, and a second press while one is pending, are swallowed here.
                if event.isARepeat || self.returnPending { return nil }
                self.returnPending = true
                let withUser = event.modifierFlags.contains(.option)
                let key = CGKeyCode(event.keyCode)
                Task { @MainActor in
                    // A click on a row selects it a moment later; and the search keeps the keyboard until Return is up,
                    // since the session stays the app in front and would get a held Return's repeats once it closed.
                    try? await Task.sleep(for: .milliseconds(150))
                    let deadline = Date().addingTimeInterval(3)
                    while Date() < deadline, CGEventSource.keyState(.hidSystemState, key: key) || CGEventSource.keyState(.combinedSessionState, key: key) {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    guard self.model === model else { return }
                    self.returnPending = false
                    if let item = Self.chosen(model) {
                        self.pick(item, withUser: withUser)
                    } else {
                        NSSound.beep()   // nothing chosen yet
                    }
                }
                return nil
            default: return event
            }
        }
        // The site is read while 1Password answers (that takes longer), so it costs no waiting.
        let reading = Task { await hosts() }
        Task { @MainActor in
            do {
                let items = try await OnePassword.list()
                // A site still being read gets a moment more; a slow one is not waited for.
                let read = await Self.value(of: reading, within: 1.5) ?? []
                let ranked = OnePassword.ranked(items, session: session, hosts: read)
                SpeedyShared.log.notice("1Password: \(ranked.items.count, privacy: .public) items listed\(ranked.host.map { ", matched to \($0)" } ?? (ranked.matched ? ", one matches the session" : ""), privacy: .public)")
                guard self.model === model else { return }
                model.items = ranked.items
                // Chosen in advance only when it fits the page or the session; otherwise the tech picks or searches.
                model.selection = ranked.matched ? ranked.items.first?.id : nil
                model.note = ranked.host.map { "Matched to \($0)" } ?? ranked.read.map { "Nothing in 1Password is saved for \($0)" }
                model.status = ranked.items.isEmpty ? "No logins in 1Password" : nil
                self.takeKeyboardBack()
            } catch let failure as OnePassword.Failure {
                SpeedyShared.log.notice("1Password: list failed: \(failure.kind, privacy: .public)")
                guard self.model === model else { return }
                model.status = failure.message
                self.takeKeyboardBack()
            } catch {
                SpeedyShared.log.notice("1Password: list failed")
                guard self.model === model else { return }
                model.status = "1Password could not be read"
                self.takeKeyboardBack()
            }
        }
    }

    /// 1Password's Touch ID prompt takes the keyboard while it lists, and gives it back to the app in front (the
    /// session), not to this search. The list only arrives once the prompt has closed: take the keyboard back then.
    private func takeKeyboardBack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
                self.takeKeyboard()
            }
        }
    }

    private func takeKeyboard() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func windowDidBecomeKey(_ notification: Notification) { model?.hasKeyboard = true }
    func windowDidResignKey(_ notification: Notification) { model?.hasKeyboard = false }

    /// The login Return would type: the selected one, else the first result of a search.
    private static func chosen(_ model: Model) -> OnePassword.Item? {
        let list = model.shown
        let searched = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return list.first(where: { $0.id == model.selection }) ?? (searched ? list.first : nil)
    }

    /// The Password key pressed again while the box is up: type the chosen login's password, as Return does.
    /// False when nothing is chosen yet.
    func pickChosen() -> Bool {
        guard let model, let item = Self.chosen(model) else { return false }
        pick(item, withUser: false)
        return true
    }

    /// A task's value if it has one within `seconds`, else nil (the task is left to finish on its own).
    private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { let v = await task.value; if once.claim() { continuation.resume(returning: v) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { continuation.resume(returning: nil) } }
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
        returnPending = false
        panel?.delegate = nil
        panel?.close()
        panel = nil
        model = nil
        onPick = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        returnPending = false
        panel = nil
        model = nil
        onPick = nil
    }
}

private struct PasswordPickerView: View {
    @ObservedObject var model: PasswordPicker.Model
    let pick: (OnePassword.Item, Bool) -> Void
    let takeKeyboard: () -> Void
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
            if !model.hasKeyboard {
                Button(action: takeKeyboard) {
                    Label("Typing is going to \(model.place), not this search. Click here to search", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let note = model.note, model.status == nil {
                Label(note, systemImage: note.hasPrefix("Matched") ? "checkmark.circle.fill" : "questionmark.circle")
                    .font(.caption).foregroundStyle(note.hasPrefix("Matched") ? Color.green : Color.secondary)
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
            Text("Return, or the Password key again, types the password into \(model.place).  ⌥Return types the username, Tab, then the password.  Esc closes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 14)
        .onAppear { searchFocused = true }
    }
}
