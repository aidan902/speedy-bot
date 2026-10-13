import AppKit
import Carbon.HIToolbox
import Combine

/// An IPv4 address, for the arithmetic behind "type only the last octet".
struct IPv4: Hashable, CustomStringConvertible, Sendable {
    let value: UInt32

    init(value: UInt32) { self.value = value }

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            v = v << 8 | UInt32(n)
        }
        value = v
    }

    init?(octets: [Int]) {
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        value = octets.reduce(0) { $0 << 8 | UInt32($1) }
    }

    var octets: [Int] { [Int(value >> 24), Int(value >> 16 & 0xFF), Int(value >> 8 & 0xFF), Int(value & 0xFF)] }
    var description: String { octets.map(String.init).joined(separator: ".") }

    static func mask(prefix: Int) -> IPv4 {
        let p = min(max(prefix, 0), 32)
        return IPv4(value: p == 0 ? 0 : ~UInt32(0) << UInt32(32 - p))
    }

    func network(prefix: Int) -> IPv4 { IPv4(value: value & Self.mask(prefix: prefix).value) }
    func broadcast(prefix: Int) -> IPv4 { IPv4(value: value | ~Self.mask(prefix: prefix).value) }

    /// The prefix length of a dotted mask ("255.255.254.0" is 23); nil when it is not a proper mask.
    static func prefix(ofMask text: String) -> Int? {
        guard let m = IPv4(text) else { return nil }
        let inverted = ~m.value
        guard inverted & (inverted &+ 1) == 0 else { return nil }   // ones, then zeros, nothing else
        return m.value.nonzeroBitCount
    }
}

/// What to run against each address. The Windows commands a tech reaches for in a session.
enum PingCommand: String, CaseIterable, Identifiable {
    case pingForever, ping, tracert, pathping, nslookup, portCheck, arp, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pingForever: return "Ping continuously (ping -t)"
        case .ping: return "Ping 4 times (ping)"
        case .tracert: return "Trace route (tracert -d)"
        case .pathping: return "Path ping, loss per hop (pathping -n)"
        case .nslookup: return "DNS name (nslookup)"
        case .portCheck: return "Port check (Test-NetConnection -Port)"
        case .arp: return "MAC address (ping once, then arp -a)"
        case .custom: return "Custom…"
        }
    }

    /// The menu title in a device row, where there is little room.
    var shortTitle: String {
        switch self {
        case .pingForever: return "ping -t"
        case .ping: return "ping"
        case .tracert: return "tracert"
        case .pathping: return "pathping"
        case .nslookup: return "nslookup"
        case .portCheck: return "port check"
        case .arp: return "arp -a"
        case .custom: return "custom"
        }
    }

    var needsPort: Bool { self == .portCheck }

    /// The command line for one address. A custom line uses `{ip}` where the address goes (or gets it on the end).
    func line(ip: String, port: Int, custom: String) -> String {
        switch self {
        case .pingForever: return "ping -t \(ip)"
        case .ping: return "ping \(ip)"
        case .tracert: return "tracert -d \(ip)"
        case .pathping: return "pathping -n \(ip)"
        case .nslookup: return "nslookup \(ip)"
        case .portCheck: return "Test-NetConnection \(ip) -Port \(port)"
        case .arp: return "ping -n 1 \(ip) | Out-Null; arp -a \(ip)"
        case .custom:
            let c = custom.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
            if c.isEmpty { return "ping -t \(ip)" }
            return c.contains("{ip}") ? c.replacingOccurrences(of: "{ip}", with: ip) : c + " " + ip
        }
    }
}

/// How each command gets its own window on the remote machine.
enum OpenVia: String, CaseIterable, Identifiable {
    /// Win+R, then `powershell -NoExit -Command …`. Works from any window of the remote desktop.
    case runDialog
    /// `Start-Process powershell …` typed into the PowerShell window the tech already has in front.
    case currentWindow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .runDialog: return "the Run dialog (⌘R reaches Windows as Win+R)"
        case .currentWindow: return "the PowerShell window that is in front"
        }
    }
}

/// One address the tech typed, resolved against the remote machine's network.
struct PingTarget: Identifiable, Equatable {
    let input: String
    let ip: IPv4?
    let problem: String?
    let insideNetwork: Bool
    var id: String { ip?.description ?? "bad:" + input }
}

enum TargetParser {
    static let maxTargets = 32

    /// `.1`, `.3 .5 .9`, `.36.200`, `10.0.0.1`, `.10-.20` (a range on the last octet), separated by spaces or
    /// commas. A short form fills in the missing octets from the remote machine's own address.
    static func parse(_ text: String, base: IPv4?, prefix: Int) -> (targets: [PingTarget], note: String?) {
        var out: [PingTarget] = []
        var seen = Set<UInt32>()
        let separators: Set<Character> = [" ", ",", ";", "\n", "\t"]
        for raw in text.split(whereSeparator: { separators.contains($0) }).map(String.init) {
            var token = raw
            while token.hasPrefix(".") { token.removeFirst() }
            while token.hasSuffix(".") { token.removeLast() }
            guard !token.isEmpty else { continue }
            // A range runs over the last octet: ".10-.20", "10-20", ".36.10-20".
            var rangeEnd: Int?
            if let dash = token.firstIndex(of: "-") {
                var right = String(token[token.index(after: dash)...])
                while right.hasPrefix(".") { right.removeFirst() }
                guard let b = Int(right), (0...255).contains(b) else {
                    out.append(PingTarget(input: raw, ip: nil, problem: "not a range", insideNetwork: false)); continue
                }
                rangeEnd = b
                token = String(token[..<dash])
                while token.hasSuffix(".") { token.removeLast() }
            }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) else {
                out.append(PingTarget(input: raw, ip: nil, problem: parts.count > 4 ? "too many parts" : "not an address", insideNetwork: false)); continue
            }
            let octets = parts.map { $0! }
            let first = octets[octets.count - 1]
            guard first <= (rangeEnd ?? first) else {
                out.append(PingTarget(input: raw, ip: nil, problem: "range runs backwards", insideNetwork: false)); continue
            }
            let fixed = Array(octets.dropLast())
            for n in first...(rangeEnd ?? first) {
                let typed = fixed + [n]
                let ip: IPv4
                if typed.count == 4 {
                    guard let full = IPv4(octets: typed) else { continue }
                    ip = full
                } else {
                    guard let base else {
                        out.append(PingTarget(input: raw, ip: nil, problem: "needs the remote machine's address", insideNetwork: false)); break
                    }
                    var o = base.octets
                    for (i, v) in typed.enumerated() { o[4 - typed.count + i] = v }
                    guard let built = IPv4(octets: o) else { continue }
                    ip = built
                }
                guard seen.insert(ip.value).inserted else { continue }
                let inside = base.map { ip.network(prefix: prefix) == $0.network(prefix: prefix) } ?? true
                out.append(PingTarget(input: raw, ip: ip, problem: nil, insideNetwork: inside))
                if out.count > maxTargets { break }
            }
        }
        var note: String?
        if out.count > maxTargets {
            out = Array(out.prefix(maxTargets))
            note = "That is a lot of windows. Only the first \(maxTargets) addresses are used."
        }
        return (out, note)
    }
}

/// The Multi Ping page: what the tech typed, the session it goes to, and the sending itself.
@MainActor
final class MultiPingState: ObservableObject {
    private unowned let app: AppState

    @Published var remoteIP: String { didSet { store(remoteIP, SpeedyShared.mpRemoteIPKey) } }
    @Published var prefix: Int { didSet { store(prefix, SpeedyShared.mpPrefixKey) } }
    @Published var gateway = ""
    @Published var hostName = ""
    @Published var publicIP = ""
    @Published var targetsText: String { didSet { store(targetsText, SpeedyShared.mpTargetsKey) } }
    @Published var command: PingCommand { didSet { store(command.rawValue, SpeedyShared.mpCommandKey) } }
    @Published var port: Int { didSet { store(port, SpeedyShared.mpPortKey) } }
    @Published var custom: String { didSet { store(custom, SpeedyShared.mpCustomKey) } }
    @Published var openVia: OpenVia { didSet { store(openVia.rawValue, SpeedyShared.mpOpenViaKey) } }
    @Published var slowRemote: Bool { didSet { store(slowRemote, SpeedyShared.mpSlowKey) } }
    /// The command above goes to every device; off, each device row has its own menu.
    @Published var applyToAll: Bool { didSet { store(applyToAll, SpeedyShared.mpApplyToAllKey) } }
    /// A device's own command, by address (used while Apply to all is off).
    @Published private(set) var rowCommands: [String: PingCommand] {
        didSet { store(rowCommands.mapValues(\.rawValue), SpeedyShared.mpRowCommandsKey) }
    }
    /// Devices left in the list but not sent to, by address.
    @Published private(set) var excluded: Set<String> {
        didSet { store(Array(excluded).sorted(), SpeedyShared.mpExcludedKey) }
    }

    @Published private(set) var sessions: [SessionWindow] = []
    @Published var selectedSession: CGWindowID?
    /// What the last send did, or is doing.
    @Published private(set) var status = ""
    @Published private(set) var probeStatus = ""
    @Published private(set) var busy = false
    @Published private(set) var probing = false

    @Published var unifiConfig = UniFiConfig.load()
    @Published private(set) var unifiHasKey = Keychain.read(account: Keychain.unifiKeyAccount) != nil
    @Published private(set) var unifi: UniFiLookup?
    @Published private(set) var unifiStatus = ""
    @Published private(set) var unifiBusy = false

    private let shell = RemoteShell()
    private var sessionTimer: Timer?
    private var probeTask: Task<Void, Never>?
    private var unifiTask: Task<Void, Never>?
    private var loading = true

    init(app: AppState) {
        self.app = app
        let d = SpeedyShared.defaults
        remoteIP = d.string(forKey: SpeedyShared.mpRemoteIPKey) ?? ""
        prefix = min(max(d.object(forKey: SpeedyShared.mpPrefixKey) as? Int ?? 24, 8), 30)
        targetsText = d.string(forKey: SpeedyShared.mpTargetsKey) ?? ""
        command = d.string(forKey: SpeedyShared.mpCommandKey).flatMap(PingCommand.init(rawValue:)) ?? .pingForever
        port = min(max(d.object(forKey: SpeedyShared.mpPortKey) as? Int ?? 443, 1), 65535)
        custom = d.string(forKey: SpeedyShared.mpCustomKey) ?? ""
        openVia = d.string(forKey: SpeedyShared.mpOpenViaKey).flatMap(OpenVia.init(rawValue:)) ?? .runDialog
        slowRemote = SpeedyShared.bool(SpeedyShared.mpSlowKey, default: false)
        applyToAll = SpeedyShared.bool(SpeedyShared.mpApplyToAllKey, default: true)
        rowCommands = (d.dictionary(forKey: SpeedyShared.mpRowCommandsKey) as? [String: String] ?? [:]).compactMapValues(PingCommand.init(rawValue:))
        excluded = Set(d.stringArray(forKey: SpeedyShared.mpExcludedKey) ?? [])
        loading = false
    }

    private func store(_ value: Any, _ key: String) {
        guard !loading else { return }
        SpeedyShared.defaults.set(value, forKey: key)
    }

    // MARK: sessions

    func startWatchingSessions() {
        refreshSessions()
        guard sessionTimer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSessions() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        sessionTimer = t
    }

    func stopWatchingSessions() {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    func refreshSessions() {
        let now = SessionWindows.all()
        if now != sessions { sessions = now }
        if let selectedSession, !now.contains(where: { $0.windowID == selectedSession }) { self.selectedSession = nil }
    }

    /// The session the commands go to: the chosen one, else the frontmost connected one.
    var session: SessionWindow? {
        sessions.first { $0.windowID == selectedSession } ?? sessions.first { $0.connected } ?? sessions.first
    }

    // MARK: the network

    var baseIP: IPv4? { IPv4(remoteIP) }
    var mask: String { IPv4.mask(prefix: prefix).description }

    var networkSummary: String? {
        guard let base = baseIP else { return nil }
        let net = base.network(prefix: prefix), bc = base.broadcast(prefix: prefix)
        let hosts = prefix >= 31 ? Int(bc.value - net.value) + 1 : max(Int(bc.value - net.value) - 1, 0)
        var s = "\(net) – \(bc) · \(hosts) addresses"
        if !gateway.isEmpty { s += " · gateway \(gateway)" }
        if !hostName.isEmpty { s += " · \(hostName)" }
        if !publicIP.isEmpty { s += " · public IP \(publicIP)" }
        return s
    }

    var parsed: (targets: [PingTarget], note: String?) { TargetParser.parse(targetsText, base: baseIP, prefix: prefix) }
    var targets: [PingTarget] { parsed.targets }
    /// The devices that get a window: resolved, and not unticked.
    var ready: [PingTarget] { targets.filter { $0.ip != nil && isIncluded($0) } }

    // MARK: per-device choices

    func isIncluded(_ target: PingTarget) -> Bool { !excluded.contains(target.id) }

    func setIncluded(_ on: Bool, for target: PingTarget) {
        if on { excluded.remove(target.id) } else { excluded.insert(target.id) }
    }

    /// The command a device gets: the one for all, or its own.
    func command(for target: PingTarget) -> PingCommand {
        applyToAll ? command : (rowCommands[target.id] ?? command)
    }

    func setCommand(_ c: PingCommand, for target: PingTarget) {
        rowCommands[target.id] = c
    }

    /// Choices kept for addresses that are no longer in the list are dropped.
    func pruneChoices() {
        let ids = Set(targets.map(\.id))
        let keptCommands = rowCommands.filter { ids.contains($0.key) }
        if keptCommands.count != rowCommands.count { rowCommands = keptCommands }
        let keptExcluded = excluded.intersection(ids)
        if keptExcluded != excluded { excluded = keptExcluded }
    }

    /// Any device row wants a port number / a custom line.
    var usesPort: Bool { command.needsPort || targets.contains { command(for: $0).needsPort } }
    var usesCustom: Bool { command == .custom || targets.contains { command(for: $0) == .custom } }

    func line(for target: PingTarget) -> String {
        command(for: target).line(ip: target.ip?.description ?? "", port: port, custom: custom)
    }

    /// What the tech chose, written the way it is typed into the session.
    var openerNote: String {
        switch openVia {
        case .runDialog: return "Each line is opened with Win+R as:  powershell -NoExit -Command \"…\""
        case .currentWindow: return "Each line is typed into the PowerShell window in front as:  Start-Process powershell '-NoExit -Command …'"
        }
    }

    // MARK: sending

    private func steps(for line: String, lastWait: Bool) -> [RemoteShell.Step] {
        let slow = slowRemote ? 2 : 1
        switch openVia {
        case .runDialog:
            // The Run dialog completes earlier entries inline; Forward Delete drops a completed tail before Return.
            return [.chord("r", command: true, shift: false), .wait(ms: 800 * slow),
                    .text("powershell -NoExit -Command \"\(line)\""), .key(CGKeyCode(kVK_ForwardDelete)), .key(CGKeyCode(kVK_Return)),
                    .wait(ms: lastWait ? 1800 * slow : 200)]
        case .currentWindow:
            let quoted = line.replacingOccurrences(of: "'", with: "''")
            return [.text("Start-Process powershell '-NoExit -Command \(quoted)'"), .key(CGKeyCode(kVK_Return)),
                    .wait(ms: lastWait ? 1200 * slow : 200)]
        }
    }

    func send() {
        guard !busy else { return }
        guard let session else { status = "No ScreenConnect session is open."; return }
        guard session.connected else { status = "\(session.name) is \(session.state?.lowercased() ?? "not connected"). Reconnect the session first."; return }
        let items = ready
        guard !items.isEmpty else { status = "Type at least one address first."; return }
        var groups: [RemoteShell.Group] = []
        for (i, t) in items.enumerated() {
            let line = self.line(for: t)
            groups.append(RemoteShell.Group(label: "Window \(i + 1) of \(items.count): \(line)",
                                            steps: steps(for: line, lastWait: i < items.count - 1)))
        }
        busy = true
        status = "Starting…"
        SpeedyShared.log.notice("multi ping: \(items.count) window(s), \(self.applyToAll ? self.command.rawValue : "per device", privacy: .public), via \(self.openVia.rawValue, privacy: .public)")
        shell.run(groups, in: session, fast: app.fastTyping, progress: { [weak self] label in
            self?.status = label
            Toast.show(label, seconds: 2.5)
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.busy = false
            self.status = Self.describe(outcome, done: "Opened \(items.count) window\(items.count == 1 ? "" : "s") in \(session.name).")
            if outcome != .done { Toast.show(self.status, seconds: 3) }
        })
    }

    func stop() { shell.cancel() }

    static func describe(_ outcome: RemoteShell.Outcome, done: String) -> String {
        switch outcome {
        case .done: return done
        case .noPermission: return "Speedy Bot needs the Accessibility permission to type into the session."
        case .sessionGone: return "That ScreenConnect session has closed."
        case .notInFront: return "Could not bring the session window to the front."
        case .chatWindow: return "The ScreenConnect chat window has focus. Click the remote screen first."
        case .capsLock: return "Caps Lock is on. Turn it off and try again."
        case .untypeable(let chars): return "This keyboard cannot type: \(chars). Nothing was sent."
        case .modifiersHeld: return "Let go of every key, then try again."
        case .stopped(let why): return why + "."
        }
    }

    // MARK: reading the remote address

    func readFromSession() {
        guard !busy, let session else { return }
        let slow = slowRemote ? 2 : 1
        let steps: [RemoteShell.Step]
        switch openVia {
        case .runDialog:
            steps = [.chord("r", command: true, shift: false), .wait(ms: 800 * slow),
                     .text("powershell -NoExit -Command \"\(SessionProbe.script)\""), .key(CGKeyCode(kVK_ForwardDelete)), .key(CGKeyCode(kVK_Return))]
        case .currentWindow:
            steps = [.text(SessionProbe.script), .key(CGKeyCode(kVK_Return))]
        }
        busy = true
        probing = true
        probeStatus = "Asking \(session.name) for its address…"
        let watch = SessionProbe.Watch(windowID: session.windowID)   // before the typing: it watches the clipboard
        probeTask?.cancel()
        shell.run([RemoteShell.Group(label: "Reading the remote machine's address…", steps: steps)], in: session, fast: app.fastTyping,
                  progress: { label in Toast.show(label, seconds: 2) },
                  completion: { [weak self] outcome in
            guard let self else { return }
            self.busy = false
            guard outcome == .done else {
                self.probing = false
                self.probeStatus = Self.describe(outcome, done: "")
                watch.cancel()
                return
            }
            self.probeStatus = "Waiting for the answer…"
            self.probeTask = Task { @MainActor [weak self] in
                let found = await watch.result(timeout: 30)
                guard let self else { return }
                self.probing = false
                guard let found else {
                    self.probeStatus = "No answer in 30 seconds. Type the address in, or try again once the PowerShell window has printed the \(SessionProbe.marker) line."
                    return
                }
                self.apply(found.reading)
                self.probeStatus = "Read from \(session.name) (via the \(found.via))."
                Toast.show("\(found.reading.ip)/\(found.reading.prefix) read from \(session.name)", seconds: 2.5)
                self.lookUpUniFi()
            }
        })
    }

    private func apply(_ r: SessionProbe.Reading) {
        remoteIP = r.ip.description
        prefix = r.prefix
        gateway = r.gateway ?? ""
        hostName = r.host ?? ""
        publicIP = r.publicIP ?? ""
        SpeedyShared.log.notice("multi ping: remote address read, prefix /\(r.prefix)")
    }

    // MARK: UniFi

    func saveUniFi(config: UniFiConfig, apiKey: String?) {
        var c = config
        c.url = UniFiConfig.normalize(c.url)
        c.save()
        unifiConfig = c
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(account: Keychain.unifiKeyAccount) } else { _ = Keychain.write(trimmed, account: Keychain.unifiKeyAccount) }
        }
        unifiHasKey = Keychain.read(account: Keychain.unifiKeyAccount) != nil
        unifi = nil
        unifiStatus = ""
    }

    private func makeClient() -> UniFiClient? {
        guard let key = Keychain.read(account: Keychain.unifiKeyAccount), !key.isEmpty else { return nil }
        return UniFiClient(config: unifiConfig, apiKey: key)
    }

    /// "N sites" or the error, for the settings sheet.
    func testUniFi(config: UniFiConfig, apiKey: String) async -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter the API key first." }
        var c = config
        c.url = UniFiConfig.normalize(c.url)
        let client = UniFiClient(config: c, apiKey: key)
        do {
            let sites = try await client.sites()
            let names = sites.prefix(4).map(\.desc).joined(separator: ", ")
            return "Connected: \(sites.count) site\(sites.count == 1 ? "" : "s") (\(names)\(sites.count > 4 ? ", …" : ")"))."
        } catch {
            return error.localizedDescription
        }
    }

    func lookUpUniFi() {
        guard let ip = baseIP else { unifiStatus = "Enter the remote machine's address first."; return }
        guard !unifiConfig.url.isEmpty, let client = makeClient() else { unifiStatus = "Set the UniFi controller and API key under Settings…"; return }
        unifiTask?.cancel()
        unifiBusy = true
        unifiStatus = "Looking up \(ip) on \(unifiConfig.host)…"
        let pub = publicIP.isEmpty ? nil : publicIP
        unifiTask = Task { @MainActor [weak self] in
            do {
                let result = try await client.lookup(ip: ip.description, publicIP: pub)
                guard let self, !Task.isCancelled else { return }
                self.unifi = result
                self.unifiStatus = ""
                SpeedyShared.log.notice("unifi lookup done: site found=\(result.site != nil) client found=\(result.client != nil)")
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.unifi = nil
                self.unifiStatus = error.localizedDescription
                SpeedyShared.log.error("unifi lookup failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.unifiBusy = false
        }
    }

    /// What UniFi knows about one of the addresses being pinged (same site as the remote machine).
    func unifiNote(for target: PingTarget) -> String? {
        guard let ip = target.ip?.description, let info = unifi?.clientsByIP[ip] else { return nil }
        return info.whereabouts
    }
}
