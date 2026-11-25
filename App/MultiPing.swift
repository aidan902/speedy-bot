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

/// How the new windows are arranged on the remote desktop once they are open.
enum TileLayout: String, CaseIterable, Identifiable {
    case sideBySide, stacked, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .stacked: return "Stacked"
        case .off: return "Leave them where they open"
        }
    }
    /// user32 TileWindows: MDITILE_VERTICAL = 0 (side by side), MDITILE_HORIZONTAL = 1 (stacked).
    var how: Int { self == .stacked ? 1 : 0 }
}

/// The one PowerShell line that opens every window (and arranges them). Typed once into the Run dialog,
/// instead of a Win+R round trip per window, so five windows take the time of one.
enum LaunchScript {
    struct Window: Equatable {
        let ip: IPv4
        let command: PingCommand
    }

    /// Stands in for the last octet while a command line is turned into a loop body.
    private static let octet = "\u{1}"

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// `'-NoExit -Command ping -t 10.1.37.'+$i` for a line that has the last octet in it (once or several times).
    private static func loopArgument(_ text: String) -> String {
        var expr = text.components(separatedBy: octet).map(quoted).joined(separator: "+$i+")
        if expr.hasSuffix("+''") { expr.removeLast(3) }
        return expr
    }

    /// The statements that open the windows: one `start powershell` per lone address, a `foreach` over the
    /// last octets for addresses that share the first three and the same command.
    static func statements(_ windows: [Window], port: Int, custom: String) -> [String] {
        var order: [String] = []
        var octets: [String: [Int]] = [:]
        for w in windows {
            let prefix = w.ip.octets.prefix(3).map(String.init).joined(separator: ".")
            let template = w.command.line(ip: prefix + "." + octet, port: port, custom: custom)
            if octets[template] == nil { order.append(template); octets[template] = [] }
            octets[template]!.append(w.ip.octets[3])
        }
        return order.map { template in
            let list = octets[template]!
            if list.count == 1 {
                return "start powershell " + quoted("-NoExit -Command " + template.replacingOccurrences(of: octet, with: String(list[0])))
            }
            return "foreach($i in \(list.map(String.init).joined(separator: ","))){start powershell (\(loopArgument("-NoExit -Command " + template)))}"
        }
    }

    /// Finds the windows that appeared since `$b` was taken (both a plain console and a Windows Terminal
    /// window count), then tiles exactly those. No double quotes anywhere (the whole line travels inside
    /// `-c "…"`) and no percent signs (the Run dialog expands %NAME% pairs).
    static func arrange(count: Int, how: Int) -> String {
        "$q=[char]34;try{Add-Type -Name W -Namespace U -Mem ('[DllImport('+$q+'user32.dll'+$q+')]public static extern int TileWindows(IntPtr p,int h,IntPtr r,int c,IntPtr[] k);');"
        + "$t=0;do{sleep -m 300;$n=@(&$f|?{$b -notcontains $_});$t++}while($n.Count -lt \(count) -and $t -lt 40);"
        + "[U.W]::TileWindows(0,\(how),0,$n.Count,[IntPtr[]]$n)}"
        // Compiling that helper can be refused on a locked-down machine: then the desktop's own tiling, which takes every window.
        + "catch{sleep 3;$x=New-Object -Com Shell.Application;if(\(how)){$x.TileHorizontally()}else{$x.TileVertically()}}"
    }

    static let handles = "$f={gps powershell,WindowsTerminal -ea 0|select -exp MainWindowHandle|?{$_ -ne 0}};$b=@(&$f);"

    /// The Run dialog takes 259 characters at most; a line longer than this goes another way.
    static let runDialogLimit = 240

    /// The whole job as PowerShell statements: open the windows, then arrange them.
    static func body(_ windows: [Window], port: Int, custom: String, tile: TileLayout) -> String {
        guard !windows.isEmpty else { return "" }
        var body = statements(windows, port: port, custom: custom).joined(separator: ";")
        if tile != .off { body = handles + body + ";" + arrange(count: windows.count, how: tile.how) }
        return body
    }

    /// A line short enough to go straight into the Run dialog, or nil when the job needs the longer way.
    static func directRunLine(_ windows: [Window], port: Int, custom: String, tile: TileLayout) -> String? {
        guard !windows.isEmpty, tile == .off else { return nil }
        let line: String
        if windows.count == 1 {
            line = "powershell -NoExit -Command \"\(windows[0].command.line(ip: windows[0].ip.description, port: port, custom: custom))\""
        } else {
            line = "powershell -Command \"\(statements(windows, port: port, custom: custom).joined(separator: ";"))\""
        }
        return line.count <= runDialogLimit ? line : nil
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
    /// How the windows are arranged once open.
    @Published var tile: TileLayout { didSet { store(tile.rawValue, SpeedyShared.mpTileKey) } }
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
        tile = d.string(forKey: SpeedyShared.mpTileKey).flatMap(TileLayout.init(rawValue:)) ?? .sideBySide
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

    private var windows: [LaunchScript.Window] { ready.map { LaunchScript.Window(ip: $0.ip!, command: command(for: $0)) } }

    /// The PowerShell that will run, for the page.
    var launchLine: String {
        if openVia == .runDialog, let direct = LaunchScript.directRunLine(windows, port: port, custom: custom, tile: tile) { return direct }
        return LaunchScript.body(windows, port: port, custom: custom, tile: tile)
    }

    /// How the PowerShell gets into the session.
    var openerNote: String {
        if openVia == .runDialog, LaunchScript.directRunLine(windows, port: port, custom: custom, tile: tile) != nil {
            return "Typed into the Run dialog (Win+R):"
        }
        let opener = openVia == .runDialog ? "a PowerShell window opened through the Run dialog (Win+R)" : "the PowerShell window in front"
        return "Pasted into \(opener) from the shared clipboard, or typed there if the clipboard is not shared:"
    }

    /// The key pace for command lines: faster than clipboard typing when the tech has chosen Fast.
    private var pace: TypingOptions { app.fastTyping ? .turbo : TypingOptions() }

    // MARK: getting a script into the session

    private var clipboardHold: ClipboardSnapshot?
    private var activeWatch: SessionProbe.Watch?

    /// Puts the tech's own clipboard back once the script has been picked up (or could not be).
    private func releaseClipboard() {
        if let hold = clipboardHold { ClipboardSwap.restore(hold) }
        clipboardHold = nil
    }

    /// Win+R, the line, Return. Forward Delete first drops the tail the Run dialog may have completed inline.
    private func runDialogSteps(typing line: String) -> [RemoteShell.Step] {
        let slow = slowRemote ? 2 : 1
        return [.chord("r", command: true, shift: false), .wait(ms: 600 * slow),
                .text(line), .key(CGKeyCode(kVK_ForwardDelete)), .key(CGKeyCode(kVK_Return))]
    }

    private func promptSteps(typing line: String) -> [RemoteShell.Step] {
        [.text(line), .key(CGKeyCode(kVK_Return))]
    }

    private func runShell(_ label: String, _ steps: [RemoteShell.Step], in session: SessionWindow, escapeStops: Bool = true,
                          progress: @escaping @MainActor @Sendable (String) -> Void) async -> RemoteShell.Outcome {
        await withCheckedContinuation { cont in
            shell.run([RemoteShell.Group(label: label, steps: steps)], in: session, pace: pace, escapeStops: escapeStops, progress: progress) { cont.resume(returning: $0) }
        }
    }

    /// Runs a PowerShell script in the session with as little typing as possible, and with nothing in any
    /// command line that security software could mistake for malware. A plain PowerShell window is opened
    /// (through the Run dialog, or the window in front) printing "SB1234 OPEN"; the script, placed on this
    /// Mac's clipboard, is pasted into it with Ctrl+V; Return is only pressed once the screen shows that what
    /// landed starts with "SB1234 RUN". Anything else is cleared and the script is typed instead.
    /// `via` reports which happened.
    private func runScript(_ script: String, in session: SessionWindow, closeWhenDone: Bool,
                           progress: @escaping @MainActor @Sendable (String) -> Void) async -> (outcome: RemoteShell.Outcome, via: String) {
        let token = SessionProbe.token()
        let ownWindow = openVia == .runDialog
        let runLine = "'SB\(token) RUN';" + script + (closeWhenDone && ownWindow ? ";exit" : "")
        // The script rides the clipboard only when the tech's own clipboard can be put back afterwards.
        var viaClipboard = false
        if let hold = ClipboardSwap.snapshot() {
            clipboardHold = hold
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(runLine, forType: .string)   // one line: a console warns before pasting several
            viaClipboard = true
        }
        let opener = "'SB\(token) OPEN'"
        let wrapped = "powershell -NoExit -Command \"\(opener)\""
        let watch = SessionProbe.Watch(windowID: session.windowID)
        activeWatch = watch
        defer { activeWatch = nil }
        SpeedyShared.log.notice("remote script: \(script.count) characters, clipboard=\(viaClipboard), via \(self.openVia.rawValue, privacy: .public)")
        let label = "Opening PowerShell in \(session.name)…"

        func opened() async -> Bool {
            await watch.wait(timeout: 10, clipboard: false) { SessionProbe.marker($0, token: token, word: "OPEN") ? true : nil } != nil
        }
        func pasted() async -> Bool {
            await watch.wait(timeout: 4, clipboard: false, every: 0.5) { SessionProbe.marker($0, token: token, word: "RUN") ? true : nil } != nil
        }

        var outcome = await runShell(label, ownWindow ? runDialogSteps(typing: wrapped) : promptSteps(typing: opener), in: session, progress: progress)
        guard outcome == .done else { releaseClipboard(); return (outcome, "none") }
        var open = await opened()
        if !open, !ownWindow {
            // Nothing in front took the opener (no PowerShell prompt there): open a window of our own.
            progress("No PowerShell prompt was in front; opening one with Win+R…")
            SpeedyShared.log.notice("remote script: the window in front did not answer; trying the Run dialog")
            outcome = await runShell(label, runDialogSteps(typing: wrapped), in: session, progress: progress)
            guard outcome == .done else { releaseClipboard(); return (outcome, "none") }
            open = await opened()
        }
        guard open else {
            releaseClipboard()
            return (.stopped("The PowerShell window did not show up on screen"), "none")
        }
        if viaClipboard {
            outcome = await runShell("Pasting the script…", [.chord("v", command: false, shift: false, control: true)], in: session, progress: progress)
            guard outcome == .done else { releaseClipboard(); return (outcome, "none") }
            if await pasted() {
                releaseClipboard()
                outcome = await runShell("Running…", [.key(CGKeyCode(kVK_Return))], in: session, progress: progress)
                return (outcome, outcome == .done ? "clipboard" : "none")
            }
            // The remote clipboard was not ours (not shared): take back whatever was pasted, then type.
            SpeedyShared.log.notice("remote script: the paste was not ours; clearing the line and typing instead")
            _ = await runShell("Clearing…", [.key(CGKeyCode(kVK_Escape)), .wait(ms: 150), .chord("c", command: false, shift: false, control: true), .wait(ms: 200)],
                               in: session, escapeStops: false, progress: progress)
        }
        releaseClipboard()
        progress("Typing the script into \(session.name)…")
        let typed = await runShell("Typing the script…", promptSteps(typing: runLine), in: session, progress: progress)
        return (typed, "typed")
    }

    // MARK: sending

    func send() {
        guard !busy else { return }
        guard let session else { status = "No ScreenConnect session is open."; return }
        guard session.connected else { status = "\(session.name) is \(session.state?.lowercased() ?? "not connected"). Reconnect the session first."; return }
        let items = ready
        guard !items.isEmpty else { status = "Type at least one address first."; return }
        let what = "\(items.count) window\(items.count == 1 ? "" : "s")"
        let arranged = tile == .off ? "" : " They tile \(tile == .stacked ? "stacked" : "side by side") once they are all open."
        busy = true
        status = "Starting…"
        SpeedyShared.log.notice("multi ping: \(items.count) window(s), \(self.applyToAll ? self.command.rawValue : "per device", privacy: .public), via \(self.openVia.rawValue, privacy: .public), tile \(self.tile.rawValue, privacy: .public)")
        let progress: @MainActor @Sendable (String) -> Void = { [weak self] label in
            self?.status = label
            Toast.show(label, seconds: 2.5)
        }
        let windows = self.windows, port = self.port, custom = self.custom, tile = self.tile
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: (outcome: RemoteShell.Outcome, via: String)
            if self.openVia == .runDialog, let direct = LaunchScript.directRunLine(windows, port: port, custom: custom, tile: tile) {
                result = (await self.runShell("Opening \(what) in \(session.name)…", self.runDialogSteps(typing: direct), in: session, progress: progress), "direct")
            } else {
                result = await self.runScript(LaunchScript.body(windows, port: port, custom: custom, tile: tile), in: session, closeWhenDone: true, progress: progress)
            }
            self.busy = false
            let how = result.via == "clipboard" ? " (script sent over the shared clipboard)" : result.via == "typed" ? " (script typed)" : ""
            self.status = Self.describe(result.outcome, done: "Sent: \(what) opening in \(session.name)\(how).\(arranged)")
            if result.outcome != .done { Toast.show(self.status, seconds: 3) }
        }
    }

    func stop() {
        shell.cancel()
        activeWatch?.cancel()
    }

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
        busy = true
        probing = true
        probeStatus = "Asking \(session.name) for its address…"
        probeTask?.cancel()
        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runScript(SessionProbe.script, in: session, closeWhenDone: false, progress: { label in Toast.show(label, seconds: 2) })
            self.busy = false
            guard result.outcome == .done else {
                self.probing = false
                self.probeStatus = Self.describe(result.outcome, done: "")
                return
            }
            self.probeStatus = "Waiting for the answer…"
            let watch = SessionProbe.Watch(windowID: session.windowID)
            self.activeWatch = watch
            let found = await watch.wait(timeout: 30, clipboard: true) { SessionProbe.parse($0) }
            self.activeWatch = nil
            self.probing = false
            guard let found else {
                self.probeStatus = "No answer in 30 seconds. Type the address in, or try again once the PowerShell window has printed the \(SessionProbe.marker) line."
                SpeedyShared.log.notice("multi ping: no \(SessionProbe.marker) line came back (script \(result.via, privacy: .public))")
                return
            }
            self.apply(found.value)
            self.probeStatus = "Read from \(session.name) (script \(result.via), answer off the \(found.via))."
            Toast.show("\(found.value.ip)/\(found.value.prefix) read from \(session.name)", seconds: 2.5)
            self.lookUpUniFi()
        }
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
