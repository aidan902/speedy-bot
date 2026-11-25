import AppKit
import Carbon.HIToolbox
import Vision
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: StatusItemController?
    private var window: MainWindowController?
    private var setup: SetupWindowController?
    private var observers: [DarwinObserver] = []
    private var isSecondCopy = false
    /// speedybot:// links that arrived before the app had finished starting (a link that launched it).
    private var pendingLinks: [URL] = []
    private var launchedByLink = false
    private var started = false

    /// The link handler has to be in place before launching finishes, or the link that started the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// speedybot://toggle and friends, from a Logitech keypad key, Shortcuts or a script.
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        if started {
            state.handle(url: url)
        } else {
            launchedByLink = true
            pendingLinks.append(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened straight from the disk image or the Downloads folder: macOS runs such a copy from a temporary,
        // read-only place, where the permission, the login item and updates do not stick.
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            isSecondCopy = true
            let alert = NSAlert()
            alert.messageText = "Move Speedy Bot to Applications first"
            alert.informativeText = "Drag Speedy Bot into the Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // One copy only. Opening the same app again just brings up its window. A copy from a DIFFERENT place
        // (a freshly downloaded update) takes over from the running one, so the tech gets what they opened.
        let me = NSRunningApplication.current
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier && $0.activationPolicy != .prohibited }   // not a diagnostic run
        for twin in twins {
            let samePlace = twin.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            // Two copies started at the same moment: the later one takes over, the earlier one carries on (the
            // process number breaks a tie, so exactly one of the two acts).
            let twinLaunch = twin.launchDate ?? .distantPast, myLaunch = me.launchDate ?? Date()
            let twinIsNewer = twinLaunch > myLaunch || (twinLaunch == myLaunch && twin.processIdentifier > me.processIdentifier)
            if samePlace {
                // Opened again from the same place: the copy already running shows its window, and this one goes.
                // When both started together, only the newer one goes (each would otherwise quit for the other).
                if twinIsNewer { continue }
                isSecondCopy = true
                SpeedyShared.post(SpeedyShared.showWindowNotification)
                NSApp.terminate(nil)
                return
            }
            if twinIsNewer { continue }
            twin.terminate()   // a normal quit: it puts the screenshot settings back on its way out
            let deadline = Date().addingTimeInterval(5)
            while !twin.isTerminated, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if !twin.isTerminated { twin.forceTerminate() }
        }

        // Started by the login item: no window, just the Dock and menu bar icons. Opened by the tech: show the window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        // Started by a link (a keypad key, a script): stay in the background like a login launch.
        launchedByLink = launchedByLink || (event?.eventClass == AEEventClass(kInternetEventClass) && event?.eventID == AEEventID(kAEGetURL))

        MainMenu.install(target: self)
        let window = MainWindowController(state: state)
        self.window = window
        state.showWindow = { [weak window] in window?.show() }
        state.showSetup = { [weak self] in self?.showSetup(askImmediately: false) }
        statusItem = StatusItemController(state: state)
        observers = [
            DarwinObserver(name: SpeedyShared.changedNotification) { [weak self] in self?.state.reloadFromStore() },
            DarwinObserver(name: SpeedyShared.showWindowNotification) { [weak self] in self?.window?.show() },
        ]
        // The keypad's action keys act only with a fresh press file from the plugin (see KeypadPress).
        let keys: [(String, AppState.KeyAction)] = [(SpeedyShared.keyTypeNotification, .type), (SpeedyShared.keyCaptureNotification, .capture),
                                                     (SpeedyShared.keyPasteNotification, .paste), (SpeedyShared.keyPasteSendNotification, .pasteSend),
                                                     (SpeedyShared.keyAutoSendNotification, .autoSend), (SpeedyShared.keyAutoMCPNotification, .autoMCP),
                                                     (SpeedyShared.keyTicketNotification, .ticket),
                                                     (SpeedyShared.keyTicket1Notification, .ticket1), (SpeedyShared.keyTicket2Notification, .ticket2),
                                                     (SpeedyShared.keyTicket3Notification, .ticket3), (SpeedyShared.keyTicketNewNotification, .ticketNew),
                                                     (SpeedyShared.keyPasswordNotification, .password)]
        for (name, action) in keys {
            observers.append(DarwinObserver(name: name) { [weak self] in
                let key = action.rawValue.lowercased()
                guard KeypadPress.consume(key) else {
                    SpeedyShared.log.notice("keypad: \(key, privacy: .public) signal ignored (no fresh press from the keypad plugin)")
                    return
                }
                self?.state.keyAction(action)
            })
        }
        state.start()
        started = true
        for link in pendingLinks { state.handle(url: link) }
        pendingLinks = []
        SpeedyShared.log.notice("launched; accessibility=\(Permissions.accessibilityTrusted) atLogin=\(launchedAtLogin) byLink=\(self.launchedByLink) pasteboardAccess=\(Permissions.pasteboardAccess, privacy: .public)")
        // The Control Center control starts the app in the background; that should not throw a window up either.
        let quietStamp = SpeedyShared.defaults.double(forKey: SpeedyShared.quietLaunchKey)
        let launchedByControl = abs(Date().timeIntervalSince1970 - quietStamp) < 15
        SpeedyShared.defaults.removeObject(forKey: SpeedyShared.quietLaunchKey)
        if !SpeedyShared.bool(SpeedyShared.setupDoneKey, default: false) {
            showSetup(askImmediately: true)   // first run: which chat app, and every permission, right away
        } else if !(launchedAtLogin || launchedByControl || launchedByLink) || !Permissions.accessibilityTrusted {
            window.show()
        }
    }

    func showSetup(askImmediately: Bool) {
        if setup == nil {
            setup = SetupWindowController(state: state) { [weak self] in
                SpeedyShared.defaults.set(true, forKey: SpeedyShared.setupDoneKey)
                self?.setup?.close()
                self?.window?.show()
            }
        }
        setup?.show(askImmediately: askImmediately)
    }

    @objc func setUpPermissions(_ sender: Any?) { showSetup(askImmediately: false) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return true
    }

    /// Closing the window leaves Speedy Bot working; Quit is what stops it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showMainWindow(_ sender: Any?) { state.page = .switches; window?.show() }

    @objc func showMultiPing(_ sender: Any?) { state.page = .multiPing; window?.show() }

    @objc func checkForUpdates(_ sender: Any?) {
        window?.show()   // the result appears at the bottom of the window
        state.updater.check(userAsked: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isSecondCopy { state.shutdown() }
    }
}

/// A diagnostic run of this binary (--check-chat, --dump-chat, …): AppKit is needed, but this process must not count
/// as a running Speedy Bot. Background-only, so an app starting at the same moment does not take it for a copy that is
/// already running and quit in its favour.
func diagnosticRun() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
}

// `--selftest`: prove the signed binary starts and its pieces load, without showing anything.
if CommandLine.arguments.contains("--selftest") {
    let map = LayoutKeyMap.current()
    print("speedybot selftest: layout=\(map?.layoutName ?? "none") keys=\(map?.map.count ?? 0) group=\(SpeedyShared.groupID)")
    // The arithmetic behind Multi Ping, checked on every build.
    var failures: [String] = []
    func expect(_ name: String, _ got: String, _ want: String) { if got != want { failures.append("\(name): got \(got), want \(want)") } }
    let base = IPv4("10.1.37.46")!
    expect("mask /23", IPv4.mask(prefix: 23).description, "255.255.254.0")
    expect("prefix of mask", String(IPv4.prefix(ofMask: "255.255.254.0") ?? -1), "23")
    expect("bad mask", String(IPv4.prefix(ofMask: "255.0.255.0") ?? -1), "-1")
    expect("network /23", base.network(prefix: 23).description, "10.1.36.0")
    expect("broadcast /23", base.broadcast(prefix: 23).description, "10.1.37.255")
    let ips = { (text: String, prefix: Int) in TargetParser.parse(text, base: base, prefix: prefix).targets.map { $0.ip?.description ?? "bad(\($0.input))" }.joined(separator: " ") }
    expect("last octet", ips(".1", 24), "10.1.37.1")
    expect("several", ips(".3 .5 .9", 24), "10.1.37.3 10.1.37.5 10.1.37.9")
    expect("two octets", ips(".36.200, 37.1", 23), "10.1.36.200 10.1.37.1")
    expect("full address", ips("10.0.0.1", 24), "10.0.0.1")
    expect("range", ips(".10-.12", 24), "10.1.37.10 10.1.37.11 10.1.37.12")
    expect("range plain", ips("10-12", 24), "10.1.37.10 10.1.37.11 10.1.37.12")
    expect("duplicates", ips(".1 .1 10.1.37.1", 24), "10.1.37.1")
    expect("bad token", ips(".300 x", 24), "bad(.300) bad(x)")
    expect("outside", String(TargetParser.parse(".36.5", base: base, prefix: 24).targets.first?.insideNetwork ?? true), "false")
    expect("inside /23", String(TargetParser.parse(".36.5", base: base, prefix: 23).targets.first?.insideNetwork ?? false), "true")
    expect("no base", TargetParser.parse(".1", base: nil, prefix: 24).targets.first?.problem ?? "nil", "needs the remote machine's address")
    expect("cap", String(TargetParser.parse("0-255", base: base, prefix: 24).targets.count), String(TargetParser.maxTargets))
    // The evening reset of the incident number: the most recent 7 pm.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    let fmt = ISO8601DateFormatter()
    fmt.timeZone = cal.timeZone
    let at = { (s: String) in fmt.date(from: s)! }
    expect("reset before 7pm", fmt.string(from: AppState.lastIncidentReset(before: at("2026-11-25T18:59:00-06:00"), calendar: cal)), "2026-11-24T19:00:00-06:00")
    expect("reset at 7pm", fmt.string(from: AppState.lastIncidentReset(before: at("2026-11-25T19:00:00-06:00"), calendar: cal)), "2026-11-25T19:00:00-06:00")
    expect("reset morning", fmt.string(from: AppState.lastIncidentReset(before: at("2026-11-26T08:00:00-06:00"), calendar: cal)), "2026-11-25T19:00:00-06:00")
    let reading = SessionProbe.parse("PS C:\\> junk\nSPEEDYBOT 10.1.37.46/23 gw=10.1.36.1 host=LAB-ROOM12 pub=203.0.113.9\nPS C:\\>")
    expect("probe ip", reading?.ip.description ?? "nil", "10.1.37.46")
    expect("probe prefix", String(reading?.prefix ?? -1), "23")
    expect("probe gw", reading?.gateway ?? "nil", "10.1.36.1")
    expect("probe host", reading?.host ?? "nil", "LAB-ROOM12")
    expect("probe pub", reading?.publicIP ?? "nil", "203.0.113.9")
    let ocr = SessionProbe.parse("SPEEDY BOT 10.1.2.3 / 24 gw=10.1.2.1 host=PC1 pub=none")
    expect("ocr spaced", "\(ocr?.ip.description ?? "nil")/\(ocr?.prefix ?? -1) \(ocr?.publicIP ?? "nopub")", "10.1.2.3/24 nopub")
    expect("script echo ignored", SessionProbe.parse("$l='SPEEDYBOT '+$a.IPAddress") == nil ? "nil" : "match", "nil")
    expect("command", PingCommand.arp.line(ip: "1.2.3.4", port: 443, custom: ""), "ping -n 1 1.2.3.4 | Out-Null; arp -a 1.2.3.4")
    expect("custom", PingCommand.custom.line(ip: "1.2.3.4", port: 443, custom: "ping -l 1400 {ip} -t"), "ping -l 1400 1.2.3.4 -t")
    expect("custom no placeholder", PingCommand.custom.line(ip: "1.2.3.4", port: 443, custom: "tracert"), "tracert 1.2.3.4")
    expect("session name", SessionWindow(pid: 1, windowID: 1, title: "ScreenConnect - LAB-ROOM12 - Connected", bounds: .zero).name, "LAB-ROOM12")
    expect("unifi url", UniFiConfig.normalize("unifi.example.com/"), "https://unifi.example.com")
    let link = { (s: String) in SpeedyLink.action(of: URL(string: s)!)?.rawValue ?? "nil" }
    expect("link toggle", link("speedybot://toggle"), "toggle")
    expect("link opaque", link("speedybot:toggle"), "toggle")
    expect("link triple slash", link("speedybot:///off"), "off")
    expect("link case", link("SPEEDYBOT://Auto"), "auto")
    expect("link alias", link("speedybot://disable"), "off")
    expect("link multiping", link("speedybot://multiping"), "multiping")
    expect("link bare", link("speedybot://"), "start")
    expect("link unknown", link("speedybot://typeit"), "nil")
    expect("link other scheme", link("https://toggle"), "nil")
    let pressDir = FileManager.default.temporaryDirectory.appendingPathComponent("speedybot-selftest-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: pressDir, withIntermediateDirectories: true)
    let press = { (key: String, body: String?) -> String in
        if let body { try? body.write(to: pressDir.appendingPathComponent(key), atomically: true, encoding: .utf8) }
        return KeypadPress.consume(key, in: pressDir) ? "yes" : "no"
    }
    let nowMs = String(Int(Date().timeIntervalSince1970 * 1000))
    expect("press fresh", press("type", nowMs), "yes")
    expect("press used up", press("type", nil), "no")
    expect("press missing", press("capture", nil), "no")
    expect("press stale", press("paste", String(Int(Date().timeIntervalSince1970 * 1000) - 10_000)), "no")
    expect("press junk", press("pastesend", "hello"), "no")
    try? FileManager.default.removeItem(at: pressDir)
    let shot = { (a: String, b: String) in ScreenshotPasteController.sameCapture(URL(fileURLWithPath: "/s/" + a), URL(fileURLWithPath: "/s/" + b)) ? "same" : "own" }
    expect("second display", shot("Screenshot 2026-10-26 at 9.15.32 PM.png", "Screenshot 2026-10-26 at 9.15.32 PM (2).png"), "same")
    expect("next screenshot", shot("Screenshot 2026-10-26 at 9.15.32 PM.png", "Screenshot 2026-10-26 at 9.15.33 PM.png"), "own")
    expect("same file", shot("Screenshot 2026-10-26 at 9.15.32 PM.png", "Screenshot 2026-10-26 at 9.15.32 PM.png"), "own")
    let w = { (ip: String, c: PingCommand) in LaunchScript.Window(ip: IPv4(ip)!, command: c) }
    expect("launch one", LaunchScript.directRunLine([w("10.1.37.4", .pingForever)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -NoExit -Command \"ping -t 10.1.37.4\"")
    expect("launch loop", LaunchScript.directRunLine([w("10.1.37.4", .pingForever), w("10.1.37.5", .pingForever), w("10.1.37.9", .pingForever)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -Command \"foreach($i in 4,5,9){start powershell ('-NoExit -Command ping -t 10.1.37.'+$i)}\"")
    expect("launch mixed", LaunchScript.body([w("10.1.37.4", .pingForever), w("10.1.37.5", .tracert), w("10.0.0.7", .pingForever)], port: 443, custom: "", tile: .off),
           "start powershell '-NoExit -Command ping -t 10.1.37.4';start powershell '-NoExit -Command tracert -d 10.1.37.5';start powershell '-NoExit -Command ping -t 10.0.0.7'")
    expect("launch arp loop", LaunchScript.statements([w("10.1.37.4", .arp), w("10.1.37.5", .arp)], port: 443, custom: "").joined(separator: ";"),
           "foreach($i in 4,5){start powershell ('-NoExit -Command ping -n 1 10.1.37.'+$i+' | Out-Null; arp -a 10.1.37.'+$i)}")
    expect("launch custom quote", LaunchScript.statements([w("10.1.37.4", .custom)], port: 443, custom: "ping -t {ip} -l 1400 'x'").joined(separator: ";"),
           "start powershell '-NoExit -Command ping -t 10.1.37.4 -l 1400 ''x'''")
    let tiled = LaunchScript.body([w("10.1.37.4", .ping), w("10.1.37.5", .ping)], port: 443, custom: "", tile: .stacked)
    expect("tile not direct", LaunchScript.directRunLine([w("10.1.37.4", .ping)], port: 443, custom: "", tile: .stacked) ?? "nil", "nil")
    expect("tile baseline", tiled.hasPrefix(LaunchScript.handles) ? "yes" : "no", "yes")
    expect("tile call", tiled.contains("-lt 2 -and $t -lt 40);[U.W]::TileWindows(0,1,0,$n.Count,[IntPtr[]]$n)}catch{") && tiled.hasSuffix("$x.TileHorizontally()}else{$x.TileVertically()}}") ? "yes" : "no", "yes")
    expect("tile no double quotes", tiled.contains("\"") ? "has quotes" : "clean", "clean")
    expect("tile no percent signs", tiled.contains("%") ? "has percent" : "clean", "clean")
    let many = (1...8).map { w("10.0.\($0).1", .pingForever) }   // eight lone addresses: well past the Run dialog's limit
    expect("long goes the other way", LaunchScript.directRunLine(many, port: 443, custom: "", tile: .off) ?? "nil", "nil")
    expect("two groups still direct", LaunchScript.directRunLine([w("10.1.37.4", .ping), w("10.1.37.5", .ping), w("10.1.36.9", .ping)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -Command \"foreach($i in 4,5){start powershell ('-NoExit -Command ping 10.1.37.'+$i)};start powershell '-NoExit -Command ping 10.1.36.9'\"")
    expect("marker open", SessionProbe.marker("PS C:\\> x\nSB7342 OPEN\n", token: "7342", word: "OPEN") ? "yes" : "no", "yes")
    expect("marker spaced", SessionProbe.marker("SB 7342OPEN", token: "7342", word: "OPEN") ? "yes" : "no", "yes")
    expect("marker other", SessionProbe.marker("SB7342 RUN", token: "7342", word: "OPEN") ? "yes" : "no", "no")
    expect("probe script short enough for a prompt, no quotes/percent", SessionProbe.script.contains("\"") || SessionProbe.script.contains("%") ? "bad" : "ok", "ok")
    let split = SessionProbe.parse("SPEEDYBOT\n10.1.37.46/23 gw=10.1.36.1\nhost=LAB-ROOM12 pub=")
    expect("probe split lines", "\(split?.ip.description ?? "nil")/\(split?.prefix ?? -1) \(split?.gateway ?? "nogw") \(split?.host ?? "nohost") \(split?.publicIP ?? "nopub")", "10.1.37.46/23 10.1.36.1 LAB-ROOM12 nopub")
    for f in failures { print("FAIL \(f)") }
    // Shortcuts pressed in a session must not leave a bare Windows-key or Alt tap on the remote.
    expect("⌃Space safe on Windows", String(HotKeySpec.defaultPassword.leavesBareModifierTapOnRemote), "false")
    expect("⌃Space label", HotKeySpec.defaultPassword.label, HotKeySpec.defaultPasswordLabel)
    expect("⌥Space refused", String(HotKeySpec(keyCode: kVK_Space, carbonModifiers: optionKey).leavesBareModifierTapOnRemote), "true")
    // The Password key: which site a page is on, and which logins fit it.
    func line(_ text: String, _ top: Double) -> SessionProbe.Line { SessionProbe.Line(text: text, top: top) }
    expect("address bar read", OnePassword.pageHosts(in: [line("Sign In", 0.3), line("someone@example.net", 0.4), line("qsys.com/nc/login/my-qsc/", 0.13)]).joined(separator: " "), "qsys.com")
    expect("bar before page text", OnePassword.pageHosts(in: [line("see help.example.com for more", 0.05), line("https://portal.fm.example.com/login", 0.2)]).first ?? "", "portal.fm.example.com")
    expect("not files, mail or versions", OnePassword.pageHosts(in: [line("report.pdf", 0.1), line("first.last@corp.com", 0.1), line("v2.42.0", 0.1)]).joined(separator: " "), "")
    expect("device address", OnePassword.pageHosts(in: [line("Not secure  10.0.0.5:8080/login", 0.1)]).joined(separator: " "), "10.0.0.5")
    expect("www dropped", OnePassword.host(of: "https://WWW.Example.com/x") ?? "nil", "example.com")
    expect("search words are not sites", OnePassword.host(of: "qsys login") ?? "nil", "nil")
    expect("site of", [OnePassword.siteDomain("login.qsys.com"), OnePassword.siteDomain("a.b.co.uk"), OnePassword.siteDomain("10.0.0.5")].joined(separator: " "), "qsys.com b.co.uk 10.0.0.5")
    expect(".fm sites", ["fm.example.com", "portal.fm.example.com", "radio.fm", "google.com", "fmsomething.com", "notfm.example.com"].map { OnePassword.typesLocally(onHost: $0) ? "y" : "n" }.joined(), "yyynyn")
    let logins = [OnePassword.Item(id: "1", title: "Q-SYS Reflect", username: "a", vault: "V", urls: ["https://qsys.com/nc/login"]),
                  OnePassword.Item(id: "2", title: "Front Desk PC", username: "b", vault: "V", urls: ["https://desk.example.com"]),
                  OnePassword.Item(id: "3", title: "QSC other", username: "c", vault: "V", urls: ["https://my.qsys.com"])]
    let bySite = OnePassword.ranked(logins, session: "ScreenConnect - Front Desk - Connected", hosts: ["qsys.com"])
    expect("site first", bySite.items.map(\.id).joined() + " \(bySite.matched) \(bySite.host ?? "-")", "132 true qsys.com")
    let tenant = OnePassword.ranked([OnePassword.Item(id: "b", title: "Client B", username: "", vault: "V", urls: ["https://clientb.sharepoint.com"])],
                                    session: "", hosts: ["clienta.sharepoint.com"])
    expect("other customer's tenant listed, not chosen", "\(tenant.items.first?.id ?? "-") \(tenant.matched) \(tenant.host ?? "-")", "b false -")
    let pageText = OnePassword.ranked([OnePassword.Item(id: "k", title: "Bank", username: "", vault: "V", urls: ["https://bank.example.com"])],
                                      session: "", hosts: ["evil.example.net", "bank.example.com"])
    expect("page text never chooses", "\(pageText.matched) \(pageText.host ?? "-") \(pageText.read ?? "-")", "false - evil.example.net")
    let inside = OnePassword.ranked([OnePassword.Item(id: "q", title: "Q", username: "", vault: "V", urls: ["https://my.qsys.com/login"])],
                                    session: "", hosts: ["qsys.com"])
    expect("one inside the other", "\(inside.matched) \(inside.host ?? "-") \(inside.savedFor ?? "-")", "true qsys.com my.qsys.com")
    // Windows sign-in, admin prompt and lock screen, read off a session window (no web address on it).
    func windows(_ texts: [String]) -> String { WindowsPrompt.read(texts.enumerated().map { line($0.element, Double($0.offset) / 10) }).map { String(describing: $0) } ?? "nil" }
    expect("other user", windows(["Other user", "User name", "Password", "Sign in to: CORP", "How do I sign in to another domain?"]), "signIn(userBox: true)")
    expect("one user", windows(["LocalAdmin", "Password", "Sign-in options"]), "signIn(userBox: false)")
    expect("lock screen", windows(["3:40", "Wednesday, November 25"]), "lockScreen")
    expect("ctrl alt del", windows(["Press Ctrl+Alt+Delete to unlock."]), "ctrlAltDel")
    expect("uac", windows(["User Account Control", "Do you want to allow this app to make changes to your device?", "User name", "Password", "Yes", "No"]), "adminPrompt(userBox: true)")
    expect("pin", windows(["PIN", "I forgot my PIN", "Sign-in options"]), "pin")
    expect("web login is not Windows", windows(["Sign In", "Email Address", "Password", "Continue"]), "nil")
    expect("local account", [WindowsPrompt.localAccount("LocalAdmin"), WindowsPrompt.localAccount("CORP\\jsmith"), WindowsPrompt.localAccount("a@b.com")].joined(separator: " "), ".\\LocalAdmin CORP\\jsmith a@b.com")
    expect("sign straight in", String(describing: WindowsPrompt.signIn(userBox: true).typing(username: "LocalAdmin", password: "pw")), String(describing: WindowsPrompt.Typing.text(".\\LocalAdmin\tpw\n")))
    expect("no user name, no typing", String(String(describing: WindowsPrompt.signIn(userBox: true).typing(username: "", password: "pw")).hasPrefix("refuse")), "true")
    expect("machine", PickMemory.machine(fromTitle: "ScreenConnect - LAB-ROOM12 - Connected") ?? "nil", "LAB-ROOM12")
    expect("name start", [PickMemory.prefix(of: "LAB-ROOM12") ?? "nil", PickMemory.prefix(of: "DESKTOP-4F2K9") ?? "nil", PickMemory.prefix(of: "FRONTDESK") ?? "nil"].joined(separator: " "), "LAB nil nil")
    let picks = ["LAB-LOBBY": PickMemory.Pick(id: "lobby", at: 1), "LAB-GYM": PickMemory.Pick(id: "gym", at: 2), "ABC-1": PickMemory.Pick(id: "abc", at: 3)]
    expect("same machine", PickMemory.choose(from: picks, machine: "LAB-LOBBY")?.id ?? "nil", "lobby")
    expect("same name start, newest", PickMemory.choose(from: picks, machine: "LAB-ROOM12")?.id ?? "nil", "gym")
    expect("unrelated machine", PickMemory.choose(from: picks, machine: "XYZ-1")?.id ?? "nil", "nil")
    let remembered = OnePassword.ranked(logins, session: "", hosts: [], preferred: "2")
    expect("remembered first", "\(remembered.items.first?.id ?? "-") \(remembered.matched) \(remembered.usedPreferred)", "2 true true")
    let rememberedButPage = OnePassword.ranked(logins, session: "", hosts: ["qsys.com"], preferred: "2")
    expect("a page's address beats memory", "\(rememberedButPage.items.first?.id ?? "-") \(rememberedButPage.usedPreferred)", "1 false")
    expect("address in a query", OnePassword.host(of: "accounts.example.com/signin?continue=https://mail.example.com/") ?? "nil", "accounts.example.com")
    let noSite = OnePassword.ranked(logins, session: "ScreenConnect - Front Desk - Connected", hosts: ["nothing.example.org"])
    expect("no site: session name", "\(noSite.items.first?.id ?? "-") \(noSite.matched) \(noSite.host ?? "-") \(noSite.read ?? "-")", "2 true - nothing.example.org")
    print("multi ping checks: \(failures.isEmpty ? "all passed" : "\(failures.count) failed")")
    exit(map == nil || !failures.isEmpty ? 1 : 0)
}

// `--probe-test`: list the ScreenConnect session windows and read the first one off the screen (nothing is typed).
if CommandLine.arguments.contains("--probe-test") {
    diagnosticRun()
    let sessions = SessionWindows.all()
    print("sessions: \(sessions.count)")
    for s in sessions { print("  pid \(s.pid) window \(s.windowID) \(Int(s.bounds.width))x\(Int(s.bounds.height)) title=\(s.title) name=\(s.name)") }
    let i = CommandLine.arguments.firstIndex(of: "--probe-test")!
    let wanted = CommandLine.arguments.count > i + 1 ? CGWindowID(CommandLine.arguments[i + 1]) : nil
    let keep = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : nil
    if let windowID = wanted ?? sessions.first?.windowID {
        // Off the main thread: the main thread is parked on the semaphore and must not be needed.
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let started = Date()
            let text = await SessionProbe.screenText(windowID: windowID, keepCaptureAt: keep)
            print("window \(windowID): text in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text == nil ? "FAILED (Screen Recording?)" : "\(text!.count) characters")")
            for line in (text ?? "").components(separatedBy: .newlines) where line.rangeOfCharacter(from: .decimalDigits) != nil { print("  | \(line)") }
            if let r = SessionProbe.parse(text ?? "") { print("  marker line found: \(r)") }
            sema.signal()
        }
        if sema.wait(timeout: .now() + 60) == .timedOut { print("timed out") }
    }
    exit(0)
}

// `--dump-chat`: wake ChatGPT the way auto-send does (never activating it) and show what auto-send reads in each
// chat app's front window: the message box (its length, never its text) and the composer's buttons.
if CommandLine.arguments.contains("--dump-chat") {
    diagnosticRun()
    let ids = ["anthropic", "openai", "chatgpt", "codex", "grok", "xai", ".x.grok"]
    let apps = NSWorkspace.shared.runningApplications.filter { app in
        let b = (app.bundleIdentifier ?? "").lowercased()
        return ids.contains { b.contains($0) } && app.activationPolicy == .regular
    }
    // Chat websites open in a browser (grok.com): each such window's message box.
    for window in WindowHitTest.onScreenWindows() {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID), PasteTarget.isBrowser(app),
              let target = PasteTarget.matching(app, window: window, in: Set(PasteTarget.allCases)) else { continue }
        let url = ChatSend.pageURL(pid: app.processIdentifier, windowID: window.windowID)
        let woke = PasteTarget.showsPageOnlyWhenAsked(app) && !ChatSend.isAwake(pid: app.processIdentifier)
        if woke {
            ChatSend.wakeAccessibility(pid: app.processIdentifier, takeOver: false)
            Thread.sleep(forTimeInterval: 0.3)
        }
        var state = Composer(pid: app.processIdentifier, windowID: window.windowID).read()
        for _ in 0..<8 where woke && state.text == nil {
            Thread.sleep(forTimeInterval: 0.25)
            state = Composer(pid: app.processIdentifier, windowID: window.windowID).read()
        }
        if woke { ChatSend.releaseAccessibility(pid: app.processIdentifier, wait: true) }
        print("== \(target.title) website in \(app.localizedName ?? "?") window \(window.windowID): host=\(url?.host ?? "unknown") box=\(state.text == nil ? "unreadable" : "\(state.text!.count) chars, typed \(state.typed?.count ?? 0)") streaming=\(state.streaming) send=\(state.sendEnabled.map { $0 ? "enabled" : "disabled" } ?? "none")")
        print("   composer buttons: \(state.buttons.joined(separator: ", "))")
    }
    print("chat apps: \(apps.count); AXIsProcessTrusted=\(AXIsProcessTrusted()); front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    for app in apps {
        let pid = app.processIdentifier
        print("== \(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "?")] awake=\(ChatSend.isAwake(pid: pid))")
        if PasteTarget.allCases.contains(where: { $0.needsAccessibilityWake && $0.matches(app) }) {
            ChatSend.wakeAccessibility(pid: pid, takeOver: false)
            for i in 1...8 where !ChatSend.isAwake(pid: pid) {
                Thread.sleep(forTimeInterval: 0.5)
                print("   t+\(Double(i) * 0.5)s awake=\(ChatSend.isAwake(pid: pid)) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            }
        }
        guard let window = WindowHitTest.frontWindow(ofPID: pid) else { print("   no window on screen"); continue }
        let state = Composer(pid: pid, windowID: window.windowID).read()
        if PasteTarget.isBrowser(app) { continue }
        print("   window \(window.windowID): box=\(state.text == nil ? "unreadable" : "\(state.text!.count) chars, typed \(state.typed?.count ?? 0)") streaming=\(state.streaming) send=\(state.sendEnabled.map { $0 ? "enabled" : "disabled" } ?? "none")")
        print("   composer buttons: \(state.buttons.joined(separator: ", "))")
    }
    ChatSend.releaseAccessibility(wait: true)   // switched back off if this run switched it on
    exit(0)
}

/// ChatGPT (the app auto-send pastes into), its front window, and its message box once its tree is awake (up to
/// `wait` seconds). For the diagnostics below; never brings ChatGPT forward.
func chatGPTBox(wait: TimeInterval) -> (app: NSRunningApplication, window: CGWindowID, composer: Composer, state: ComposerState)? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { PasteTarget.chatGPT.matches($0) }) else { return nil }
    guard let window = WindowHitTest.frontWindow(ofPID: app.processIdentifier) else { return nil }
    ChatSend.wakeAccessibility(pid: app.processIdentifier, takeOver: false)
    let composer = Composer(pid: app.processIdentifier, windowID: window.windowID)
    var state = composer.read()
    let deadline = Date().addingTimeInterval(wait)
    while state.text == nil, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        state = composer.read()
    }
    return (app, window.windowID, composer, state)
}

func describe(_ s: ComposerState) -> String {
    "box=\(s.text == nil ? "unreadable" : "\(s.typed?.count ?? 0) chars typed") streaming=\(s.streaming) send=\(s.sendEnabled.map { $0 ? "enabled" : "disabled" } ?? "none") pictures=\(s.images) extras=\(s.extras) buttons=[\(s.buttons.joined(separator: ", "))]"
}

/// The CGWindowID behind an accessibility window (for the probe below).
@_silgen_name("_AXUIElementGetWindow")
private func probeWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// `--ax-probe BUNDLE_ID`: what accessibility shows of an app (its windows, the two "expose yourself" switches, and the
// roles in its front window), before and after asking it to show everything. For working out a chat app that cannot
// be read. Prints roles, labels and sizes only, never text.
if let i = CommandLine.arguments.firstIndex(of: "--ax-probe"), CommandLine.arguments.count > i + 1 {
    diagnosticRun()
    let bid = CommandLine.arguments[i + 1]
    func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else { print("probe: \(bid) not running"); exit(2) }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    func show(_ when: String) {
        let windows = attr(el, kAXWindowsAttribute) as? [AXUIElement] ?? []
        print("probe \(when): pid=\(app.processIdentifier) enhanced=\(String(describing: attr(el, "AXEnhancedUserInterface"))) manual=\(String(describing: attr(el, "AXManualAccessibility"))) windows=\(windows.count)")
        for w in windows {
            var id: CGWindowID = 0
            _ = probeWindowID(w, &id)
            var counts: [String: Int] = [:]
            var labels: [String] = []
            var queue = [w]; var seen = 0
            while !queue.isEmpty, seen < 20000 {
                let e = queue.removeFirst(); seen += 1
                let role = attr(e, kAXRoleAttribute) as? String ?? "?"
                counts[role, default: 0] += 1
                if role == "AXButton", labels.count < 40 {
                    let l = (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? ""
                    if !l.isEmpty { labels.append(l) }
                }
                if role == "AXTextArea" || role == "AXTextField" {
                    let focused = (attr(e, kAXFocusedAttribute) as? Bool) == true
                    let len = (attr(e, kAXValueAttribute) as? String)?.count ?? -1
                    print("   text element: \(role) focused=\(focused) valueLength=\(len) desc=\((attr(e, kAXDescriptionAttribute) as? String) ?? "")")
                }
                if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
            let top = counts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("  window \(id) title?=\((attr(w, kAXTitleAttribute) as? String)?.isEmpty == false) elements=\(seen): \(top)")
            print("   buttons: \(labels.joined(separator: " | "))")
        }
    }
    show("before")
    let manual = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let enhanced = AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    print("probe: set manual=\(manual.rawValue) enhanced=\(enhanced.rawValue)")
    func size() -> Int {
        guard let w = (attr(el, kAXWindowsAttribute) as? [AXUIElement])?.first else { return 0 }
        var queue = [w]; var seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst(); seen += 1
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return seen
    }
    for t in 1...20 {
        Thread.sleep(forTimeInterval: 0.5)
        let focused = attr(el, kAXFocusedUIElementAttribute).map { attr($0 as! AXUIElement, kAXRoleAttribute) as? String ?? "?" } ?? "none"
        print("  t+\(Double(t) / 2)s: elements=\(size()) focused=\(focused) manual=\(String(describing: attr(el, "AXManualAccessibility")))")
        if size() > 60 { break }
    }
    show("after")
    AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    exit(0)
}

// `--ocr-bottom WINDOW_ID [FRACTION]`: the text in the bottom part of a window (default the lowest quarter), with where
// each line sits (x, y from the bottom, width, as fractions of the window). For working out a chat app's message box
// when accessibility cannot see it. Only that strip is read.
if let i = CommandLine.arguments.firstIndex(of: "--ocr-bottom"), CommandLine.arguments.count > i + 1, let wid = UInt32(CommandLine.arguments[i + 1]) {
    let fraction = CommandLine.arguments.count > i + 2 ? Double(CommandLine.arguments[i + 2]) ?? 0.25 : 0.25
    let path = NSTemporaryDirectory() + "speedybot-ocr-\(getpid()).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(wid), path]
    try? task.run(); task.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("ocr: capture failed"); exit(1) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: fraction)
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    print("ocr: window \(wid) \(cg.width)x\(cg.height), bottom \(Int(fraction * 100))%")
    for r in request.results ?? [] {
        guard let text = r.topCandidates(1).first?.string else { continue }
        // Bounding boxes come back in the region's own coordinates: back to the whole window.
        let b = r.boundingBox
        print(String(format: "  x=%.2f y=%.3f w=%.2f  %@", b.minX, b.minY * fraction, b.width, text))
    }
    exit(0)
}

// `--browser-probe`: the browser windows on screen, whether their title mentions Grok, and the host each one's page is
// from (read through accessibility). Only titles that mention Grok are printed. For telling a grok.com tab apart.
if CommandLine.arguments.contains("--browser-probe") {
    diagnosticRun()
    func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    let browsers = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for app in NSWorkspace.shared.runningApplications where browsers.contains(app.bundleIdentifier ?? "") {
        let pid = app.processIdentifier
        print("== \(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "")] pid \(pid)")
        for d in raw where (d[kCGWindowOwnerPID as String] as? pid_t) == pid && (d[kCGWindowLayer as String] as? Int) == 0 {
            let title = d[kCGWindowName as String] as? String ?? ""
            let id = d[kCGWindowNumber as String] as? CGWindowID ?? 0
            print("  window \(id): title \(title.isEmpty ? "(none)" : title.localizedCaseInsensitiveContains("grok") ? "\"\(title)\"" : "(no Grok)")")
        }
        // The page each window shows: the web area's URL, host only.
        let el = AXUIElementCreateApplication(pid)
        for w in attr(el, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            var queue = [w]; var seen = 0; var hosts: [String] = []
            while !queue.isEmpty, seen < 3000 {
                let e = queue.removeFirst(); seen += 1
                if (attr(e, kAXRoleAttribute) as? String) == "AXWebArea" {
                    if let url = attr(e, "AXURL") as? URL { hosts.append(url.host ?? "?") } else { hosts.append("(no URL)") }
                    continue
                }
                if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
            let doc = (attr(w, "AXDocument") as? String).flatMap { URL(string: $0)?.host } ?? "-"
            print("  ax window: AXDocument host=\(doc) web areas=\(hosts) elements=\(seen)")
        }
    }
    exit(0)
}

// `--check-1password`: can `op` reach the 1Password app when Speedy Bot starts it? Start this copy through
// LaunchServices (open -n -a "Speedy Bot" --args --check-1password) so macOS counts it as Speedy Bot, as it does the
// running app; the answer is printed and logged ("check-1password:").
if CommandLine.arguments.contains("--check-1password") {
    diagnosticRun()
    var report = OnePassword.connectionReport()
    // Which site the Password key would match: the remote browser in each ScreenConnect session window (read off the
    // screen), and the page in each browser on this Mac (and whether it is a .fm site, where it types here).
    let done = DispatchSemaphore(value: 0)
    final class Lines: @unchecked Sendable { var all: [String] = [] }
    let found = Lines()
    let sessions = NSWorkspace.shared.runningApplications.filter { FrontmostAppGate.isScreenConnect($0) }.compactMap { WindowHitTest.frontWindow(ofPID: $0.processIdentifier) }
    let browsers = NSWorkspace.shared.runningApplications.filter { PasteTarget.isBrowser($0) }.map { ($0.processIdentifier, $0.localizedName ?? "browser") }
    Task.detached {
        for w in sessions {
            let started = Date()
            let lines = await SessionProbe.screenLines(windowID: w.windowID) ?? []
            let hosts = OnePassword.pageHosts(in: lines)
            let windows = hosts.isEmpty ? WindowsPrompt.read(lines).map { "Windows: \($0.note)" } ?? "no site or Windows sign-in read" : hosts.joined(separator: ", ")
            let remembered = PickMemory.machine(fromTitle: w.title).flatMap(PickMemory.recall(machine:)).map { "; remembered: \($0.note)" } ?? ""
            found.all.append("session \"\(w.title)\": \(windows)\(remembered) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        }
        for (pid, name) in browsers {
            let started = Date()
            let page = await OnePassword.browserPage(pid: pid)
            let host = page.host ?? "no address read"
            let local = page.host.map { OnePassword.typesLocally(onHost: $0) ? "types here (.fm)" : "not .fm" } ?? ""
            found.all.append("\(name): \(host) \(local)\(page.inBrowserField ? ", keyboard in the browser's own field" : "") (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        }
        done.signal()
    }
    done.wait()
    report += found.all
    for line in report {
        print("check-1password: \(line)")
        SpeedyShared.log.notice("check-1password: \(line, privacy: .public)")
    }
    exit(0)
}

// `--check-chat`: would auto-send send into ChatGPT's message box as it is right now? The same rule auto-send uses
// (ScreenshotPasteController.sendBlocker), so a change in how ChatGPT draws its box shows up here, at install,
// instead of as screenshots that quietly stop sending. Exit 0: would send; 1: would not; 2: no ChatGPT to look at.
if CommandLine.arguments.contains("--check-chat") {
    diagnosticRun()
    guard let chat = chatGPTBox(wait: 4) else {
        print("check-chat: ChatGPT is not open (or has no window on this desktop); nothing to check")
        ChatSend.releaseAccessibility(wait: true)
        exit(2)
    }
    print("check-chat: \(describe(chat.state))")
    let blocker = ScreenshotPasteController.sendBlocker(chat.state, ours: nil)
    ChatSend.releaseAccessibility(wait: true)
    if let blocker {
        print(blocker == "unreadable"
              ? "check-chat: WOULD NOT SEND: the message box could not be read"
              : "check-chat: WOULD NOT SEND: the box reads as holding something (empty it in ChatGPT and check again; if it IS empty, ChatGPT has changed and auto-send needs a fix)")
        exit(1)
    }
    print("check-chat: OK, auto-send would send into this box")
    exit(0)
}

// `--test-background-paste`: try putting a test picture into ChatGPT's message box WITHOUT bringing ChatGPT forward:
// first its own Edit > Paste menu item through accessibility, then Cmd+V posted to its process. Reports what the box
// shows after each and whether ChatGPT came forward; removes the test picture again and puts the clipboard back.
if CommandLine.arguments.contains("--test-background-paste") {
    diagnosticRun()
    func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
    func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
    guard let chat = chatGPTBox(wait: 4), chat.state.text != nil else {
        print("bg-paste: ChatGPT's message box could not be read (is ChatGPT open with a window on this desktop?)")
        ChatSend.releaseAccessibility(wait: true)
        exit(2)
    }
    let pid = chat.app.processIdentifier
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
        print("bg-paste: ChatGPT is the app in front; click another app first so the test means something")
        ChatSend.releaseAccessibility(wait: true)
        exit(2)
    }
    print("bg-paste: front app = \(front()); before: \(describe(chat.state))")
    // A small test picture.
    let image = NSImage(size: NSSize(width: 240, height: 90))
    image.lockFocus()
    NSColor.systemYellow.setFill(); NSRect(x: 0, y: 0, width: 240, height: 90).fill()
    ("Speedy Bot test" as NSString).draw(at: NSPoint(x: 20, y: 35), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(3) }
    let saved = ClipboardSwap.snapshot()
    // A second, private type on the item: the running Speedy Bot does not take this for a screenshot (and send it).
    NSPasteboard.general.clearContents()
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    item.setString("test", forType: NSPasteboard.PasteboardType("net.fm.speedybot.test"))
    NSPasteboard.general.writeObjects([item])
    func changed(_ s: ComposerState) -> Bool {
        s.extras > chat.state.extras || s.images > chat.state.images || (s.sendButton != nil && chat.state.sendButton == nil)
    }
    func settle() -> ComposerState {
        var s = chat.composer.read()
        for _ in 0..<8 where !changed(s) { Thread.sleep(forTimeInterval: 0.25); s = chat.composer.read() }
        return s
    }
    var worked: String?
    // A: Edit > Paste through accessibility.
    let appEl = AXUIElementCreateApplication(pid)
    var pasteItem: AXUIElement?
    if let bar = attr(appEl, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
       let items = attr(bar, kAXChildrenAttribute) as? [AXUIElement],
       let edit = items.first(where: { title($0) == "Edit" }),
       let menu = (attr(edit, kAXChildrenAttribute) as? [AXUIElement])?.first,
       let paste = (attr(menu, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { title($0) == "Paste" }) {
        pasteItem = paste
        let err = AXUIElementPerformAction(paste, kAXPressAction as CFString)
        let after = settle()
        print("bg-paste A (Edit > Paste menu item): press=\(err.rawValue) front app now = \(front()); after: \(describe(after))")
        if changed(after) { worked = "A" }
    } else {
        print("bg-paste A: could not find ChatGPT's Edit > Paste menu item")
    }
    // C: its window made main and its box focused through accessibility (no activation), then Edit > Paste.
    if worked == nil, let paste = pasteItem {
        let r = chat.composer.focusQuietly()
        Thread.sleep(forTimeInterval: 0.3)
        let err = AXUIElementPerformAction(paste, kAXPressAction as CFString)
        let after = settle()
        print("bg-paste C (window main + box focused, then Edit > Paste): main=\(r.main.rawValue) focus=\(r.focus.rawValue) press=\(err.rawValue) front app now = \(front()); after: \(describe(after))")
        if changed(after) { worked = "C" }
    }
    // B: Cmd+V posted to ChatGPT's process only (after C has focused its box).
    if worked == nil {
        let src = CGEventSource(stateID: .privateState)
        let v = LayoutKeyMap.keyCodeWithCommand(for: "v") ?? 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.postToPid(pid); up?.postToPid(pid)
        let after = settle()
        print("bg-paste B (Cmd+V posted to ChatGPT's process): front app now = \(front()); after: \(describe(after))")
        if changed(after) { worked = "B" }
    }
    // Clean up: take the test picture out again, and give the clipboard back.
    Thread.sleep(forTimeInterval: 1.0)
    if worked != nil {
        let now = chat.composer.read()
        print("bg-paste: test picture in the box; its remove button: \(now.buttons.filter { $0.hasPrefix("remove") })")
    }
    if let saved { ClipboardSwap.restore(saved) }
    ChatSend.releaseAccessibility(wait: true)
    print(worked.map { "bg-paste: RESULT: method \($0) put the picture in with ChatGPT in the background" } ?? "bg-paste: RESULT: neither method pasted with ChatGPT in the background")
    exit(worked == nil ? 1 : 0)
}

// `--restore-screenshot-settings`: put the screenshot settings back without starting the app (used by uninstall).
if CommandLine.arguments.contains("--restore-screenshot-settings") {
    ScreencapturePrefs.restore()
    exit(0)
}

// `--snapshot-setup <file.png>`: the same for the first-run setup window.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-setup"), CommandLine.arguments.count > i + 1 {
    diagnosticRun()
    let host = NSHostingView(rootView: SetupView(state: AppState(), status: SetupStatus(), onDone: {}).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    var ok = false
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) != nil
    }
    exit(ok ? 0 : 1)
}

// `--snapshot <file.png>` / `--snapshot-ping <file.png>`: draw a page of the window to a picture without showing
// it (for the README and checks).
for (flag, page) in [("--snapshot", MainPage.switches), ("--snapshot-ping", MainPage.multiPing)] {
    if let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 {
        _ = NSApplication.shared
        exit(MainWindowController.snapshot(state: AppState(), page: page, to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // a normal app: Dock icon, its own menus, Cmd+Tab

// A polite kill (an installer, a logout script, `kill`) must quit the same way Quit does, because quitting is
// what puts the tech's screenshot settings back.
let quitSignals: [DispatchSourceSignal] = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    return source
}

app.run()
