import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: StatusItemController?
    private var window: MainWindowController?
    private var setup: SetupWindowController?
    private var observers: [DarwinObserver] = []
    private var isSecondCopy = false

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
            .filter { $0.processIdentifier != me.processIdentifier }
        for twin in twins {
            let samePlace = twin.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            // Two copies started at the same moment: the later one takes over, the earlier one carries on.
            let twinIsNewer = (twin.launchDate ?? .distantPast) > (me.launchDate ?? Date())
            if samePlace {
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
        state.start()
        SpeedyShared.log.notice("launched; accessibility=\(Permissions.accessibilityTrusted) atLogin=\(launchedAtLogin) pasteboardAccess=\(Permissions.pasteboardAccess, privacy: .public)")
        // The Control Center control starts the app in the background; that should not throw a window up either.
        let quietStamp = SpeedyShared.defaults.double(forKey: SpeedyShared.quietLaunchKey)
        let launchedByControl = abs(Date().timeIntervalSince1970 - quietStamp) < 15
        SpeedyShared.defaults.removeObject(forKey: SpeedyShared.quietLaunchKey)
        if !SpeedyShared.bool(SpeedyShared.setupDoneKey, default: false) {
            showSetup(askImmediately: true)   // first run: which chat app, and every permission, right away
        } else if !(launchedAtLogin || launchedByControl) || !Permissions.accessibilityTrusted {
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

// `--selftest`: prove the signed binary starts and its pieces load, without showing anything.
if CommandLine.arguments.contains("--selftest") {
    let map = LayoutKeyMap.current()
    print("speedybot selftest: layout=\(map?.layoutName ?? "none") keys=\(map?.map.count ?? 0) group=\(SpeedyShared.groupID)")
    // The arithmetic behind Multi Ping, checked on every build.
    var failures: [String] = []
    func expect(_ name: String, _ got: String, _ want: String) { if got != want { failures.append("\(name): got \(got), want \(want)") } }
    let base = IPv4("172.16.37.46")!
    expect("mask /23", IPv4.mask(prefix: 23).description, "255.255.254.0")
    expect("prefix of mask", String(IPv4.prefix(ofMask: "255.255.254.0") ?? -1), "23")
    expect("bad mask", String(IPv4.prefix(ofMask: "255.0.255.0") ?? -1), "-1")
    expect("network /23", base.network(prefix: 23).description, "172.16.36.0")
    expect("broadcast /23", base.broadcast(prefix: 23).description, "172.16.37.255")
    let ips = { (text: String, prefix: Int) in TargetParser.parse(text, base: base, prefix: prefix).targets.map { $0.ip?.description ?? "bad(\($0.input))" }.joined(separator: " ") }
    expect("last octet", ips(".1", 24), "172.16.37.1")
    expect("several", ips(".3 .5 .9", 24), "172.16.37.3 172.16.37.5 172.16.37.9")
    expect("two octets", ips(".36.200, 37.1", 23), "172.16.36.200 172.16.37.1")
    expect("full address", ips("10.0.0.1", 24), "10.0.0.1")
    expect("range", ips(".10-.12", 24), "172.16.37.10 172.16.37.11 172.16.37.12")
    expect("range plain", ips("10-12", 24), "172.16.37.10 172.16.37.11 172.16.37.12")
    expect("duplicates", ips(".1 .1 172.16.37.1", 24), "172.16.37.1")
    expect("bad token", ips(".300 x", 24), "bad(.300) bad(x)")
    expect("outside", String(TargetParser.parse(".36.5", base: base, prefix: 24).targets.first?.insideNetwork ?? true), "false")
    expect("inside /23", String(TargetParser.parse(".36.5", base: base, prefix: 23).targets.first?.insideNetwork ?? false), "true")
    expect("no base", TargetParser.parse(".1", base: nil, prefix: 24).targets.first?.problem ?? "nil", "needs the remote machine's address")
    expect("cap", String(TargetParser.parse("0-255", base: base, prefix: 24).targets.count), String(TargetParser.maxTargets))
    let reading = SessionProbe.parse("PS C:\\> junk\nSPEEDYBOT 172.16.37.46/23 gw=172.16.36.1 host=FLC-JACKSON pub=203.0.113.9\nPS C:\\>")
    expect("probe ip", reading?.ip.description ?? "nil", "172.16.37.46")
    expect("probe prefix", String(reading?.prefix ?? -1), "23")
    expect("probe gw", reading?.gateway ?? "nil", "172.16.36.1")
    expect("probe host", reading?.host ?? "nil", "FLC-JACKSON")
    expect("probe pub", reading?.publicIP ?? "nil", "203.0.113.9")
    let ocr = SessionProbe.parse("SPEEDY BOT 10.1.2.3 / 24 gw=10.1.2.1 host=PC1 pub=none")
    expect("ocr spaced", "\(ocr?.ip.description ?? "nil")/\(ocr?.prefix ?? -1) \(ocr?.publicIP ?? "nopub")", "10.1.2.3/24 nopub")
    expect("script echo ignored", SessionProbe.parse("$l='SPEEDYBOT '+$a.IPAddress") == nil ? "nil" : "match", "nil")
    expect("command", PingCommand.arp.line(ip: "1.2.3.4", port: 443, custom: ""), "ping -n 1 1.2.3.4 | Out-Null; arp -a 1.2.3.4")
    expect("custom", PingCommand.custom.line(ip: "1.2.3.4", port: 443, custom: "ping -l 1400 {ip} -t"), "ping -l 1400 1.2.3.4 -t")
    expect("custom no placeholder", PingCommand.custom.line(ip: "1.2.3.4", port: 443, custom: "tracert"), "tracert 1.2.3.4")
    expect("session name", SessionWindow(pid: 1, windowID: 1, title: "ScreenConnect - FLC-JACKSON - Connected", bounds: .zero).name, "FLC-JACKSON")
    expect("unifi url", UniFiConfig.normalize("unifi.fm.net/"), "https://unifi.fm.net")
    let w = { (ip: String, c: PingCommand) in LaunchScript.Window(ip: IPv4(ip)!, command: c) }
    expect("launch one", LaunchScript.directRunLine([w("172.16.37.4", .pingForever)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -NoExit -Command \"ping -t 172.16.37.4\"")
    expect("launch loop", LaunchScript.directRunLine([w("172.16.37.4", .pingForever), w("172.16.37.5", .pingForever), w("172.16.37.9", .pingForever)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -Command \"foreach($i in 4,5,9){start powershell ('-NoExit -Command ping -t 172.16.37.'+$i)}\"")
    expect("launch mixed", LaunchScript.body([w("172.16.37.4", .pingForever), w("172.16.37.5", .tracert), w("10.0.0.7", .pingForever)], port: 443, custom: "", tile: .off),
           "start powershell '-NoExit -Command ping -t 172.16.37.4';start powershell '-NoExit -Command tracert -d 172.16.37.5';start powershell '-NoExit -Command ping -t 10.0.0.7'")
    expect("launch arp loop", LaunchScript.statements([w("172.16.37.4", .arp), w("172.16.37.5", .arp)], port: 443, custom: "").joined(separator: ";"),
           "foreach($i in 4,5){start powershell ('-NoExit -Command ping -n 1 172.16.37.'+$i+' | Out-Null; arp -a 172.16.37.'+$i)}")
    expect("launch custom quote", LaunchScript.statements([w("172.16.37.4", .custom)], port: 443, custom: "ping -t {ip} -l 1400 'x'").joined(separator: ";"),
           "start powershell '-NoExit -Command ping -t 172.16.37.4 -l 1400 ''x'''")
    let tiled = LaunchScript.body([w("172.16.37.4", .ping), w("172.16.37.5", .ping)], port: 443, custom: "", tile: .stacked)
    expect("tile not direct", LaunchScript.directRunLine([w("172.16.37.4", .ping)], port: 443, custom: "", tile: .stacked) ?? "nil", "nil")
    expect("tile baseline", tiled.hasPrefix(LaunchScript.handles) ? "yes" : "no", "yes")
    expect("tile call", tiled.contains("-lt 2 -and $t -lt 40);[U.W]::TileWindows(0,1,0,$n.Count,[IntPtr[]]$n)}catch{") && tiled.hasSuffix("$x.TileHorizontally()}else{$x.TileVertically()}}") ? "yes" : "no", "yes")
    expect("tile no double quotes", tiled.contains("\"") ? "has quotes" : "clean", "clean")
    expect("tile no percent signs", tiled.contains("%") ? "has percent" : "clean", "clean")
    let many = (1...8).map { w("10.0.\($0).1", .pingForever) }   // eight lone addresses: well past the Run dialog's limit
    expect("long goes the other way", LaunchScript.directRunLine(many, port: 443, custom: "", tile: .off) ?? "nil", "nil")
    expect("two groups still direct", LaunchScript.directRunLine([w("172.16.37.4", .ping), w("172.16.37.5", .ping), w("172.16.36.9", .ping)], port: 443, custom: "", tile: .off) ?? "nil",
           "powershell -Command \"foreach($i in 4,5){start powershell ('-NoExit -Command ping 172.16.37.'+$i)};start powershell '-NoExit -Command ping 172.16.36.9'\"")
    expect("marker open", SessionProbe.marker("PS C:\\> x\nSB7342 OPEN\n", token: "7342", word: "OPEN") ? "yes" : "no", "yes")
    expect("marker spaced", SessionProbe.marker("SB 7342OPEN", token: "7342", word: "OPEN") ? "yes" : "no", "yes")
    expect("marker other", SessionProbe.marker("SB7342 RUN", token: "7342", word: "OPEN") ? "yes" : "no", "no")
    expect("probe script short enough for a prompt, no quotes/percent", SessionProbe.script.contains("\"") || SessionProbe.script.contains("%") ? "bad" : "ok", "ok")
    let split = SessionProbe.parse("SPEEDYBOT\n172.16.37.46/23 gw=172.16.36.1\nhost=FLC-JACKSON pub=")
    expect("probe split lines", "\(split?.ip.description ?? "nil")/\(split?.prefix ?? -1) \(split?.gateway ?? "nogw") \(split?.host ?? "nohost") \(split?.publicIP ?? "nopub")", "172.16.37.46/23 172.16.36.1 FLC-JACKSON nopub")
    for f in failures { print("FAIL \(f)") }
    print("multi ping checks: \(failures.isEmpty ? "all passed" : "\(failures.count) failed")")
    exit(map == nil || !failures.isEmpty ? 1 : 0)
}

// `--probe-test`: list the ScreenConnect session windows and read the first one off the screen (nothing is typed).
if CommandLine.arguments.contains("--probe-test") {
    _ = NSApplication.shared
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

// `--restore-screenshot-settings`: put the screenshot settings back without starting the app (used by uninstall).
if CommandLine.arguments.contains("--restore-screenshot-settings") {
    ScreencapturePrefs.restore()
    exit(0)
}

// `--snapshot-setup <file.png>`: the same for the first-run setup window.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-setup"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
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
