import AppKit
import Combine
import ServiceManagement
import WidgetKit

/// Off, on, or on only while a ScreenConnect session is open.
enum MasterMode: String, CaseIterable, Identifiable {
    case off, on, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }
}

/// The switches, where they are stored, and what turns on and off when they change.
/// Settings live in the app group so the Control Center control can flip the master switch.
@MainActor
final class AppState: ObservableObject {
    /// Off / On / Auto. Auto means "only while a ScreenConnect session is open".
    @Published var mode: MasterMode {
        didSet {
            guard !reloading, mode != oldValue else { return }
            SpeedyShared.defaults.set(mode.rawValue, forKey: SpeedyShared.modeKey)
            SpeedyShared.defaults.set(mode != .off, forKey: SpeedyShared.enabledKey)   // what the Control Center control shows
            apply()
            reloadControl()
        }
    }
    /// A ScreenConnect session client is running on this Mac.
    @Published private(set) var screenConnectOpen = false
    /// Not switched off (the options are usable). Whether anything is actually running is `active`.
    var masterEnabled: Bool { mode != .off }
    /// Speedy Bot is doing its job right now.
    var active: Bool { mode == .on || (mode == .auto && screenConnectOpen) }
    @Published var screenshotPaste: Bool { didSet { changed(SpeedyShared.screenshotPasteKey, screenshotPaste) } }
    @Published var remoteTyping: Bool { didSet { changed(SpeedyShared.remoteTypingKey, remoteTyping) } }
    @Published var fastTyping: Bool { didSet { changed(SpeedyShared.fastTypingKey, fastTyping) } }
    /// Keep a copy of every screenshot under SpeedyBot Documentation, filed by incident number.
    @Published var saveScreenshots: Bool { didSet { changed(SpeedyShared.saveScreenshotsKey, saveScreenshots) } }
    /// Leave the system's screenshot behaviour alone (saved file, corner preview) and use the saved file.
    @Published var keepNormalScreenshots: Bool { didSet { changed(SpeedyShared.keepNormalScreenshotsKey, keepNormalScreenshots) } }
    /// What makes a waiting screenshot go into ChatGPT.
    @Published var pasteTrigger: PasteTrigger {
        didSet {
            guard !reloading else { return }
            SpeedyShared.defaults.set(pasteTrigger.rawValue, forKey: SpeedyShared.pasteTriggerKey)
            apply()
        }
    }
    /// In the pointer-rest mode, a screenshot that has waited longer than `staleAfterSeconds` needs a double-click.
    @Published var staleDoubleClick: Bool { didSet { changed(SpeedyShared.staleDoubleClickKey, staleDoubleClick) } }
    @Published var staleAfterSeconds: Int {
        didSet {
            guard !reloading, staleAfterSeconds != oldValue else { return }
            SpeedyShared.defaults.set(staleAfterSeconds, forKey: SpeedyShared.staleAfterKey)
            apply()
        }
    }
    /// One shortcut captures the whole ScreenConnect session window.
    @Published var captureWindow: Bool { didSet { changed(SpeedyShared.captureWindowKey, captureWindow) } }
    /// The tech's own shortcut for that capture (nil = the standard ⌘⇧2).
    @Published private(set) var captureShortcut: HotKeySpec?
    /// The shortcut for the keyboard-shortcut paste trigger (nil until the tech records one).
    @Published private(set) var pasteShortcut: HotKeySpec?
    /// The tech's own shortcut for typing into a session (nil = the standard ⌘⇧V).
    @Published private(set) var typingShortcut: HotKeySpec?
    /// Why screenshots are not being seen, when they are not (shown in the window).
    @Published private(set) var screenshotNote: String?
    /// Canonical incident label ("#INC - 12,345"), or "" when none is set.
    @Published private(set) var incident: String
    @Published private(set) var docsRoot: URL

    @Published private(set) var accessibilityGranted = Permissions.accessibilityTrusted
    @Published private(set) var launchAtLogin = LoginItem.status == .enabled
    @Published private(set) var loginItemNote: String?
    /// A screenshot is waiting for the pointer to reach ChatGPT.
    @Published var armed = false
    /// Clipboard text is being typed into a remote session right now.
    @Published var typing = false

    var showWindow: (() -> Void)?

    private lazy var screenshot = ScreenshotPasteController(state: self)
    private lazy var typer = RemoteTypingController(state: self)
    private lazy var capture = WindowCaptureController(state: self)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reloading = false
    private var permissionTimer: Timer?

    init() {
        mode = Self.storedMode()
        staleDoubleClick = SpeedyShared.bool(SpeedyShared.staleDoubleClickKey, default: false)
        staleAfterSeconds = max(1, SpeedyShared.defaults.object(forKey: SpeedyShared.staleAfterKey) as? Int ?? 30)
        captureWindow = SpeedyShared.bool(SpeedyShared.captureWindowKey, default: true)
        captureShortcut = HotKeySpec.load(.capture)
        screenshotPaste = SpeedyShared.bool(SpeedyShared.screenshotPasteKey, default: true)
        remoteTyping = SpeedyShared.bool(SpeedyShared.remoteTypingKey, default: true)
        fastTyping = SpeedyShared.bool(SpeedyShared.fastTypingKey, default: false)
        saveScreenshots = SpeedyShared.bool(SpeedyShared.saveScreenshotsKey, default: false)
        keepNormalScreenshots = SpeedyShared.bool(SpeedyShared.keepNormalScreenshotsKey, default: false)
        pasteTrigger = SpeedyShared.defaults.string(forKey: SpeedyShared.pasteTriggerKey).flatMap(PasteTrigger.init(rawValue:)) ?? .hover
        pasteShortcut = HotKeySpec.load(.paste)
        typingShortcut = HotKeySpec.load(.typing)
        incident = SpeedyShared.defaults.string(forKey: SpeedyShared.incidentKey) ?? ""
        docsRoot = SpeedyShared.defaults.string(forKey: SpeedyShared.docsFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Documentation.defaultRoot
    }

    /// The stored mode, reconciled with the plain on/off switch the Control Center control flips.
    private static func storedMode() -> MasterMode {
        let enabled = SpeedyShared.bool(SpeedyShared.enabledKey, default: true)
        let stored = SpeedyShared.defaults.string(forKey: SpeedyShared.modeKey).flatMap(MasterMode.init(rawValue:))
        if !enabled { return .off }
        if let stored, stored != .off { return stored }
        return .on
    }

    private func senseScreenConnect() {
        let open = NSWorkspace.shared.runningApplications.contains(where: FrontmostAppGate.isScreenConnect)
        guard open != screenConnectOpen else { return }
        screenConnectOpen = open
        SpeedyShared.log.notice("ScreenConnect session is \(open ? "open" : "closed", privacy: .public)")
        apply()
    }

    func start() {
        screenConnectOpen = NSWorkspace.shared.runningApplications.contains(where: FrontmostAppGate.isScreenConnect)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.senseScreenConnect() }
            })
        }
        SpeedyShared.defaults.set(true, forKey: SpeedyShared.appRunningKey)
        reloadControl()
        screenshot.onScreenshot = { [weak self] ref in self?.saveScreenshotIfWanted(ref) }
        apply()
        // The Accessibility switch lives in System Settings; notice when the tech flips it.
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    /// Put the Mac back the way it was: the screenshot settings return to the tech's own values.
    func shutdown() {
        screenshot.stop()
        typer.setEnabled(false)
        capture.setEnabled(false)
        ScreencapturePrefs.restore()
        SpeedyShared.defaults.set(false, forKey: SpeedyShared.appRunningKey)
        reloadControl()
    }

    private func reloadControl() {
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: SpeedyShared.controlKind) }
    }

    /// The Control Center control (or another copy of the app) changed the stored switches.
    func reloadFromStore() {
        reloading = true
        mode = Self.storedMode()
        SpeedyShared.defaults.set(mode.rawValue, forKey: SpeedyShared.modeKey)
        screenshotPaste = SpeedyShared.bool(SpeedyShared.screenshotPasteKey, default: true)
        remoteTyping = SpeedyShared.bool(SpeedyShared.remoteTypingKey, default: true)
        fastTyping = SpeedyShared.bool(SpeedyShared.fastTypingKey, default: false)
        saveScreenshots = SpeedyShared.bool(SpeedyShared.saveScreenshotsKey, default: false)
        keepNormalScreenshots = SpeedyShared.bool(SpeedyShared.keepNormalScreenshotsKey, default: false)
        pasteTrigger = SpeedyShared.defaults.string(forKey: SpeedyShared.pasteTriggerKey).flatMap(PasteTrigger.init(rawValue:)) ?? .hover
        reloading = false
        apply()
    }

    private func changed(_ key: String, _ value: Bool) {
        guard !reloading else { return }
        SpeedyShared.defaults.set(value, forKey: key)
        apply()
        if key == SpeedyShared.saveScreenshotsKey, value, incident.isEmpty {
            // Ask which incident the screenshots belong to, once the switch has finished flipping.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.askForIncident() } }
        }
    }

    private func apply() {
        screenshot.trigger = pasteTrigger
        screenshot.shortcut = pasteShortcut
        screenshot.pasteEnabled = screenshotPaste
        // Resting the pointer pastes a fresh screenshot; an old one then needs a double-click (if the tech wants that).
        screenshot.hoverMaxAge = staleDoubleClick ? TimeInterval(max(1, staleAfterSeconds)) : nil
        screenshotNote = nil
        if !(active && (screenshotPaste || saveScreenshots)) {
            screenshot.stop()
            ScreencapturePrefs.restore()
        } else if keepNormalScreenshots {
            // The tech's own screenshot settings stay exactly as they are; the saved file is picked up instead.
            ScreencapturePrefs.restore()
            if ScreencapturePrefs.sendsToClipboard {
                screenshot.start(source: .clipboard)
            } else {
                let folder = ScreencapturePrefs.screenshotFolder
                if !screenshot.start(source: .folder(folder)) {
                    screenshotNote = "Speedy Bot cannot see your screenshot folder (\(folder.lastPathComponent)). Allow it under System Settings > Privacy & Security > Files & Folders, then switch this off and on."
                    SpeedyShared.log.error("cannot watch the screenshot folder")
                }
            }
        } else {
            // Screenshots go straight to the clipboard, so the paste is instant.
            ScreencapturePrefs.applyClipboardMode()
            screenshot.start(source: .clipboard)
        }
        typer.setEnabled(active && remoteTyping)
        capture.setEnabled(active && captureWindow && screenConnectOpen)
    }

    /// Where screenshots are being looked for right now (nil when neither screenshot feature is running).
    var screenshotSource: ScreenshotSource? { screenshot.source }

    // MARK: shortcuts

    var captureShortcutLabel: String { (captureShortcut ?? WindowCaptureController.defaultShortcut).label }

    func setCaptureShortcut(_ spec: HotKeySpec?) {
        captureShortcut = spec
        HotKeySpec.save(spec, .capture)
        apply()
    }

    var typingShortcutLabel: String { typingShortcut?.label ?? HotKeySpec.defaultLabel }

    func setTypingShortcut(_ spec: HotKeySpec?) {
        typingShortcut = spec
        HotKeySpec.save(spec, .typing)
        typer.shortcutChanged()
    }

    func setPasteShortcut(_ spec: HotKeySpec?) {
        pasteShortcut = spec
        HotKeySpec.save(spec, .paste)
        apply()
    }

    // MARK: documentation

    /// What is in the incident field right now, before Return or a click elsewhere commits it.
    var incidentDraft: String?

    func setIncident(_ raw: String) {
        incidentDraft = nil
        let value = Incident.canonical(raw)
        guard value != incident else { return }
        incident = value
        SpeedyShared.defaults.set(value, forKey: SpeedyShared.incidentKey)
    }

    func askForIncident() {
        if let answer = IncidentPrompt.ask(current: incident) { setIncident(answer) }
    }

    func setDocsRoot(_ url: URL) {
        docsRoot = url
        SpeedyShared.defaults.set(url.path, forKey: SpeedyShared.docsFolderKey)
    }

    func chooseDocsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where Speedy Bot keeps saved screenshots."
        panel.directoryURL = docsRoot.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { setDocsRoot(url) }
    }

    /// Opens the current incident's folder (or the top folder when it has no screenshots yet).
    func openDocsFolder() {
        let fm = FileManager.default
        let incidentFolder = Documentation.folder(root: docsRoot, incident: incident)
        if fm.fileExists(atPath: incidentFolder.path) { NSWorkspace.shared.open(incidentFolder); return }
        try? fm.createDirectory(at: docsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(docsRoot)
    }

    private func saveScreenshotIfWanted(_ ref: ScreenshotRef) {
        guard active, saveScreenshots else { return }
        if let draft = incidentDraft { setIncident(draft) }   // a number typed but not yet confirmed still counts
        let shot: (data: Data, ext: String)
        switch ref {
        case .clipboard:
            guard let onClipboard = Documentation.screenshotOnClipboard() else {
                SpeedyShared.log.notice("screenshot could not be read from the clipboard for saving")
                Toast.show("Could not read the screenshot to save it. Allow Speedy Bot under Privacy & Security > Paste from Other Apps", seconds: 5)
                return
            }
            shot = onClipboard
        case .file(let url):
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                SpeedyShared.log.notice("screenshot file could not be read for saving")
                return
            }
            shot = (data, url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
        }
        let root = docsRoot, incident = self.incident
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Documentation.save(shot.data, ext: shot.ext, root: root, incident: incident) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let url):
                        _ = url
                        SpeedyShared.log.notice("screenshot saved for documentation")
                        Toast.show("Saved to " + (incident.isEmpty ? Incident.unfiledFolder : incident), seconds: 1.4)
                    case .failure(let error):
                        SpeedyShared.log.error("screenshot save failed: \(error.localizedDescription, privacy: .private)")
                        Toast.show("Could not save the screenshot: \(error.localizedDescription)", seconds: 4)
                    }
                }
            }
        }
    }

    private func refreshPermission() {
        senseScreenConnect()   // in case a launch or quit notification was missed
        if active && (screenshotPaste || saveScreenshots) {
            if keepNormalScreenshots {
                // The tech may change where screenshots are saved, or point them at the clipboard; follow them.
                let wanted: ScreenshotSource = ScreencapturePrefs.sendsToClipboard ? .clipboard : .folder(ScreencapturePrefs.screenshotFolder)
                if screenshot.source != nil, screenshot.source != wanted { apply() }
            } else {
                ScreencapturePrefs.reassertIfDrifted()
            }
        }
        let now = Permissions.accessibilityTrusted
        if now != accessibilityGranted {
            accessibilityGranted = now
            SpeedyShared.log.notice("accessibility permission is now \(now ? "granted" : "missing", privacy: .public)")
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibilityPrompt()
        NSWorkspace.shared.open(Permissions.accessibilitySettingsURL)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(enabled: on)
            loginItemNote = nil
        } catch {
            loginItemNote = "Could not change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.status == .enabled
        if on, LoginItem.status == .requiresApproval {
            loginItemNote = "Allow Speedy Bot under System Settings > General > Login Items."
        }
    }
}
