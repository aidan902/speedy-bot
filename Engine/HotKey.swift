// Carbon RegisterEventHotKey wrapper + "only while app X is frontmost" gate.
// No TCC permission needed. The key combo is swallowed while registered and untouched while unregistered.
import AppKit
import Carbon.HIToolbox

@MainActor
public final class GlobalHotKey {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let action: @MainActor () -> Void

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var handlerInstalled = false
    private static let signature: OSType = 0x53704274 // 'SpBt'

    public init(keyCode: Int, carbonModifiers: Int, action: @escaping @MainActor () -> Void) {
        self.keyCode = UInt32(keyCode); self.carbonModifiers = UInt32(carbonModifiers); self.action = action
        self.id = GlobalHotKey.nextID; GlobalHotKey.nextID += 1
    }

    public var isRegistered: Bool { ref != nil }

    /// Returns the OSStatus (0 = noErr, -9878 = eventHotKeyExistsErr when registered with the exclusive option elsewhere).
    @discardableResult public func register() -> OSStatus {
        guard ref == nil else { return noErr }
        GlobalHotKey.installHandlerIfNeeded()
        var r: EventHotKeyRef?
        let st = RegisterEventHotKey(keyCode, carbonModifiers, EventHotKeyID(signature: GlobalHotKey.signature, id: id),
                                     GetEventDispatcherTarget(), 0, &r)
        if st == noErr { ref = r; GlobalHotKey.registry[id] = self }
        return st
    }

    @discardableResult public func unregister() -> OSStatus {
        guard let r = ref else { return noErr }
        ref = nil; GlobalHotKey.registry[id] = nil
        return UnregisterEventHotKey(r)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers on the main thread's event loop (NSApplication.run pumps it), so hopping with assumeIsolated is safe.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr else { return st }
            let hotKeyID = hk.id
            MainActor.assumeIsolated { GlobalHotKey.registry[hotKeyID]?.action() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Keeps a hotkey registered only while an app matching `matches` is frontmost.
@MainActor
public final class FrontmostAppGate {
    private let hotKey: GlobalHotKey
    private let matches: (NSRunningApplication) -> Bool
    private var observer: NSObjectProtocol?
    public var enabled = false { didSet { sync() } }

    public init(hotKey: GlobalHotKey, matches: @escaping (NSRunningApplication) -> Bool) {
        self.hotKey = hotKey; self.matches = matches
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    public func sync() {
        let front = NSWorkspace.shared.frontmostApplication
        if enabled, let front, matches(front) { hotKey.register() } else { hotKey.unregister() }
    }

    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        hotKey.unregister()
    }

    /// ScreenConnect session client. Bundle id `com.screenconnect.client` (verified on 25.8; the unattended agent is
    /// `com.screenconnect.client.access`). Older ConnectWise Control-branded builds are matched by name.
    public static func isScreenConnect(_ app: NSRunningApplication) -> Bool {
        let bid = (app.bundleIdentifier ?? "").lowercased()
        // The unattended-access agent on the tech's own Mac is not a session window.
        if bid == "com.screenconnect.client.access" { return false }
        if bid.hasPrefix("com.screenconnect.client") { return true }
        let name = (app.localizedName ?? "").lowercased()
        return name.contains("screenconnect") || name.contains("connectwisecontrol") || name.contains("connectwise control")
    }
}
