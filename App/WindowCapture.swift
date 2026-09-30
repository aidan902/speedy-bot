import AppKit
import Carbon.HIToolbox

/// One press (Cmd+Shift+2 unless the tech chose another shortcut) takes a screenshot of the whole ScreenConnect
/// session window, with no dragging. The picture then goes the same way as any other screenshot: into ChatGPT
/// on the paste trigger, and into the documentation folder if that is on.
///
/// The capture itself is done by the system's own `screencapture` tool, so the result is exactly what
/// Cmd+Shift+4 on that window would give. macOS asks for the Screen Recording permission the first time.
@MainActor
final class WindowCaptureController {
    static let defaultShortcut = HotKeySpec(keyCode: kVK_ANSI_2, carbonModifiers: cmdKey | shiftKey)

    private unowned let state: AppState
    private var hotKey: GlobalHotKey?
    private var registered: HotKeySpec?
    private var capturing = false

    init(state: AppState) { self.state = state }

    /// The shortcut is only claimed while it can do something (the feature is on and a session is open), so it
    /// keeps whatever other meaning it has the rest of the time.
    func setEnabled(_ on: Bool) {
        let wanted = on ? (state.captureShortcut ?? Self.defaultShortcut) : nil
        guard wanted != registered else { return }
        hotKey?.unregister()
        hotKey = nil
        registered = wanted
        guard let wanted else { return }
        let hk = GlobalHotKey(keyCode: wanted.keyCode, carbonModifiers: wanted.carbonModifiers) { [weak self] in self?.fire() }
        hk.register()
        hotKey = hk
    }

    /// The session window: ScreenConnect's biggest ordinary window that is not its Chat or Status window.
    private func sessionWindow() -> CGWindowID? {
        let pids = Set(NSWorkspace.shared.runningApplications.filter(FrontmostAppGate.isScreenConnect).map(\.processIdentifier))
        guard !pids.isEmpty,
              let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, area: CGFloat)?
        for d in raw {
            guard let pid = d[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (d[kCGWindowLayer as String] as? Int) == 0,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.width >= 200, r.height >= 150, let id = d[kCGWindowNumber as String] as? CGWindowID else { continue }
            // Window names are only readable once Screen Recording is allowed; without them size decides.
            if let name = d[kCGWindowName as String] as? String, name.hasPrefix("Chat - ") || name.hasPrefix("Status - ") { continue }
            let area = r.width * r.height
            if best == nil || area > best!.area { best = (id, area) }
        }
        return best?.id
    }

    private func fire() {
        guard !capturing else { return }
        guard let windowID = sessionWindow() else {
            Toast.show("No ScreenConnect session window to capture", seconds: 2.5)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()   // shows the system prompt the first time
            Toast.show("Allow Speedy Bot under Privacy & Security > Screen Recording, then press the shortcut again", seconds: 5)
            state.showWindow?()
            return
        }

        // Where the picture goes follows the screenshot setting: a file in the tech's screenshot folder when
        // Speedy Bot is leaving their normal behaviour alone, otherwise the clipboard.
        var args = ["-o", "-l", String(windowID)]   // -o: without the window's shadow
        var file: URL?
        if case .folder(let folder) = state.screenshotSource {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
            let url = folder.appendingPathComponent("Screenshot \(stamp.string(from: Date())).png")
            args.append(url.path)
            file = url
        } else {
            args.append("-c")
        }

        let savedTo = file
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = args
        task.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(status: status, file: savedTo) }
            }
        }
        do {
            capturing = true
            try task.run()
            SpeedyShared.log.notice("capturing the session window")
        } catch {
            capturing = false
            Toast.show("Could not start the screenshot tool", seconds: 3)
        }
    }

    private func finished(status: Int32, file: URL?) {
        capturing = false
        if let file, FileManager.default.fileExists(atPath: file.path) {
            // Mark the file the way the system marks its own screenshots, so it is picked up like one.
            if let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) {
                value.withUnsafeBytes { _ = setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
            }
        } else if status != 0 || file != nil {
            SpeedyShared.log.error("session window capture failed (status \(status))")
            Toast.show("Could not capture the ScreenConnect window", seconds: 3)
        }
    }
}
