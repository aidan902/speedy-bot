import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: StatusItemController?
    private var window: MainWindowController?
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
        if !(launchedAtLogin || launchedByControl) || !Permissions.accessibilityTrusted { window.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return true
    }

    /// Closing the window leaves Speedy Bot working; Quit is what stops it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showMainWindow(_ sender: Any?) { window?.show() }

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
    exit(map == nil ? 1 : 0)
}

// `--restore-screenshot-settings`: put the screenshot settings back without starting the app (used by uninstall).
if CommandLine.arguments.contains("--restore-screenshot-settings") {
    ScreencapturePrefs.restore()
    exit(0)
}

// `--snapshot <file.png>`: draw the window's contents to a picture without showing it (for the README and checks).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    exit(MainWindowController.snapshot(state: AppState(), to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
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
