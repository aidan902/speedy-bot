import AppKit

/// A lock-protected Bool shared between the main thread and the typing thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = false) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Listens for one Darwin notification and calls back on the main actor.
final class DarwinObserver: @unchecked Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(name: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler
                Task { @MainActor in handler() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}

/// While screenshot paste is on, Cmd+Shift+3/4/5 must put the picture on the clipboard straight away.
/// That is two system screenshot settings: the destination, and the floating thumbnail (which holds the
/// picture back for about five seconds). The tech's own values are remembered and put back when the
/// feature is switched off or the app quits.
enum ScreencapturePrefs {
    private static var domain: CFString { "com.apple.screencapture" as CFString }
    /// `target-screenshot` is what current macOS reads; `target` is the older name; `show-thumbnail` is the delay.
    private static let keys = ["target-screenshot", "target", "show-thumbnail"]
    private static let savedKey = "screencapture.saved"

    private static func get(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetValue(key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func sync() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static var isApplied: Bool { SpeedyShared.defaults.object(forKey: savedKey) != nil }

    static func applyClipboardMode() {
        sync()
        let d = SpeedyShared.defaults
        if d.object(forKey: savedKey) == nil {
            var saved: [String: Any] = [:]
            for k in keys { if let v = get(k) { saved[k] = v } }
            d.set(saved, forKey: savedKey)
        }
        set("target-screenshot", "clipboard" as CFString)
        set("target", "clipboard" as CFString)
        set("show-thumbnail", kCFBooleanFalse)
        sync()
    }

    /// Cmd+Shift+5 > Options (or anything else) can point screenshots back at a file while a screenshot feature
    /// is on, which would silently stop it working. Put clipboard mode back; the remembered values stay as they were.
    static func reassertIfDrifted() {
        guard isApplied else { return }
        sync()
        let target = get("target-screenshot") as? String
        let thumbnail = get("show-thumbnail") as? Bool
        guard target != "clipboard" || thumbnail != false else { return }
        SpeedyShared.log.notice("screenshot settings were changed while a screenshot feature is on; sending screenshots to the clipboard again")
        set("target-screenshot", "clipboard" as CFString)
        set("target", "clipboard" as CFString)
        set("show-thumbnail", kCFBooleanFalse)
        sync()
    }

    static func restore() {
        let d = SpeedyShared.defaults
        guard let saved = d.dictionary(forKey: savedKey) else { return }
        sync()
        for k in keys { set(k, saved[k] as CFPropertyList?) }   // a key the tech never had is removed again
        sync()
        d.removeObject(forKey: savedKey)
    }
}

/// A small, click-through message that never takes keyboard focus.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, seconds: TimeInterval = 2.0) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text

        let size = label?.fittingSize ?? NSSize(width: 200, height: 20)
        let w = min(max(size.width + 36, 160), 560), h = size.height + 22
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 24, width: w, height: h), display: true)

        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .labelColor
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            l.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -18),
        ])
        p.contentView = blur
        label = l
        return p
    }
}
