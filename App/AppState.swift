import AppKit
import Combine
import ServiceManagement
import WidgetKit

/// The switches, where they are stored, and what turns on and off when they change.
/// Settings live in the app group so the Control Center control can flip the master switch.
@MainActor
final class AppState: ObservableObject {
    @Published var masterEnabled: Bool { didSet { changed(SpeedyShared.enabledKey, masterEnabled) } }
    @Published var screenshotPaste: Bool { didSet { changed(SpeedyShared.screenshotPasteKey, screenshotPaste) } }
    @Published var remoteTyping: Bool { didSet { changed(SpeedyShared.remoteTypingKey, remoteTyping) } }
    @Published var fastTyping: Bool { didSet { changed(SpeedyShared.fastTypingKey, fastTyping) } }
    /// Keep a copy of every screenshot under SpeedyBot Documentation, filed by incident number.
    @Published var saveScreenshots: Bool { didSet { changed(SpeedyShared.saveScreenshotsKey, saveScreenshots) } }
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
    private var reloading = false
    private var permissionTimer: Timer?

    init() {
        masterEnabled = SpeedyShared.bool(SpeedyShared.enabledKey, default: true)
        screenshotPaste = SpeedyShared.bool(SpeedyShared.screenshotPasteKey, default: true)
        remoteTyping = SpeedyShared.bool(SpeedyShared.remoteTypingKey, default: true)
        fastTyping = SpeedyShared.bool(SpeedyShared.fastTypingKey, default: false)
        saveScreenshots = SpeedyShared.bool(SpeedyShared.saveScreenshotsKey, default: false)
        incident = SpeedyShared.defaults.string(forKey: SpeedyShared.incidentKey) ?? ""
        docsRoot = SpeedyShared.defaults.string(forKey: SpeedyShared.docsFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Documentation.defaultRoot
    }

    func start() {
        SpeedyShared.defaults.set(true, forKey: SpeedyShared.appRunningKey)
        reloadControl()
        screenshot.onScreenshot = { [weak self] in self?.saveScreenshotIfWanted() }
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
        masterEnabled = SpeedyShared.bool(SpeedyShared.enabledKey, default: true)
        screenshotPaste = SpeedyShared.bool(SpeedyShared.screenshotPasteKey, default: true)
        remoteTyping = SpeedyShared.bool(SpeedyShared.remoteTypingKey, default: true)
        fastTyping = SpeedyShared.bool(SpeedyShared.fastTypingKey, default: false)
        saveScreenshots = SpeedyShared.bool(SpeedyShared.saveScreenshotsKey, default: false)
        reloading = false
        apply()
    }

    private func changed(_ key: String, _ value: Bool) {
        guard !reloading else { return }
        SpeedyShared.defaults.set(value, forKey: key)
        apply()
        if key == SpeedyShared.enabledKey { reloadControl() }
        if key == SpeedyShared.saveScreenshotsKey, value, incident.isEmpty {
            // Ask which incident the screenshots belong to, once the switch has finished flipping.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.askForIncident() } }
        }
    }

    private func apply() {
        // Both screenshot features work from the clipboard, so either one needs screenshots sent there.
        if masterEnabled && (screenshotPaste || saveScreenshots) {
            ScreencapturePrefs.applyClipboardMode()
            screenshot.pasteEnabled = screenshotPaste
            screenshot.start()
        } else {
            screenshot.stop()
            ScreencapturePrefs.restore()
        }
        typer.setEnabled(masterEnabled && remoteTyping)
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

    private func saveScreenshotIfWanted() {
        guard masterEnabled, saveScreenshots else { return }
        if let draft = incidentDraft { setIncident(draft) }   // a number typed but not yet confirmed still counts
        guard let shot = Documentation.screenshotOnClipboard() else {
            SpeedyShared.log.notice("screenshot could not be read from the clipboard for saving")
            Toast.show("Could not read the screenshot to save it. Allow Speedy Bot under Privacy & Security > Paste from Other Apps", seconds: 5)
            return
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
        if masterEnabled && (screenshotPaste || saveScreenshots) { ScreencapturePrefs.reassertIfDrifted() }
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
