import AppKit
import Combine

/// The menu bar icon and its menu: the same switches as the window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observation: AnyCancellable?

    init(state: AppState) {
        self.state = state
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // objectWillChange fires before the value lands; redraw on the next turn of the run loop.
        observation = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshIcon() } }
        }
        refreshIcon()
    }

    private func refreshIcon() {
        let name: String
        if !state.active { name = "hare" }
        else if state.typing { name = "keyboard.fill" }
        else if state.armed { name = "photo.fill" }
        else { name = "hare.fill" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Speedy Bot")
        image?.isTemplate = true
        item.button?.image = image
        switch state.mode {
        case .off: item.button?.toolTip = "Speedy Bot is off"
        case .auto where !state.screenConnectOpen: item.button?.toolTip = "Speedy Bot is waiting for a ScreenConnect session"
        default: item.button?.toolTip = state.armed ? "Speedy Bot: a screenshot is waiting to go into \(state.pasteTargetNames)" : "Speedy Bot is on"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Speedy Bot", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(choice("On", symbol: "power", on: state.mode == .on, #selector(setOn)))
        menu.addItem(choice("Auto: only while ScreenConnect is open", symbol: "bolt.horizontal", on: state.mode == .auto, #selector(setAuto)))
        menu.addItem(choice("Off", symbol: "poweroff", on: state.mode == .off, #selector(setOff)))
        menu.addItem(.separator())
        let features = [
            toggle("Paste screenshots into \(state.pasteTargetNames)", symbol: "photo.on.rectangle.angled", on: state.screenshotPaste, #selector(toggleScreenshot)),
            toggle("\(state.typingShortcutLabel) types into ScreenConnect", symbol: "keyboard", on: state.remoteTyping, #selector(toggleTyping)),
            toggle("\(state.captureShortcutLabel) captures the ScreenConnect window", symbol: "macwindow.badge.plus", on: state.captureWindow, #selector(toggleCapture)),
            toggle("Save screenshots for documentation", symbol: "folder.badge.plus", on: state.saveScreenshots, #selector(toggleSave)),
        ]
        for f in features {
            f.isEnabled = state.masterEnabled
            menu.addItem(f)
        }
        if state.saveScreenshots {
            menu.addItem(action("Incident: " + (state.incident.isEmpty ? "not set" : state.incident) + "…", #selector(incident)))
            menu.addItem(action("Open Documentation Folder", #selector(openDocs)))
        }
        if !state.accessibilityGranted {
            menu.addItem(.separator())
            menu.addItem(action("Grant Accessibility Permission…", #selector(grant)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Check for Updates…", #selector(checkUpdates)))
        menu.addItem(action("Open Speedy Bot…", #selector(open)))
        menu.addItem(action("Quit Speedy Bot", #selector(quit), key: "q"))
    }

    /// A feature switch: a round blue check box like the ones in the window, instead of a tick.
    private func toggle(_ title: String, symbol: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let i = action(title, selector)
        i.image = Self.checkIcon(on: on)
        return i
    }

    /// One of several choices: the chosen one gets the blue check box, the others an empty ring.
    private func choice(_ title: String, symbol: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let i = action(title, selector)
        i.image = Self.checkIcon(on: on)
        return i
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    private static var iconCache: [Bool: NSImage] = [:]

    /// A round check box: blue with a white tick when on, an empty grey ring when off. Drawn once into a bitmap
    /// (menus do not always call an image's drawing handler), in colours that read in light and dark menus.
    private static func checkIcon(on: Bool, size: CGFloat = 18) -> NSImage {
        if let cached = iconCache[on] { return cached }
        let scale: CGFloat = 2
        let px = Int(size * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        if on {
            NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).setFill()   // system blue
            circle.fill()
            let tick = NSBezierPath()
            tick.lineWidth = 2.2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.move(to: NSPoint(x: size * 0.28, y: size * 0.50))
            tick.line(to: NSPoint(x: size * 0.44, y: size * 0.34))
            tick.line(to: NSPoint(x: size * 0.73, y: size * 0.66))
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            NSColor(white: 0.55, alpha: 0.9).setStroke()
            circle.lineWidth = 1.4
            circle.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        image.isTemplate = false
        iconCache[on] = image
        return image
    }

    @objc private func setOn() { state.mode = .on }
    @objc private func setAuto() { state.mode = .auto }
    @objc private func setOff() { state.mode = .off }
    @objc private func toggleScreenshot() { state.screenshotPaste.toggle() }
    @objc private func toggleTyping() { state.remoteTyping.toggle() }
    @objc private func toggleCapture() { state.captureWindow.toggle() }
    @objc private func toggleSave() { state.saveScreenshots.toggle() }
    @objc private func incident() { state.askForIncident() }
    @objc private func openDocs() { state.openDocsFolder() }
    @objc private func grant() { state.requestAccessibility() }
    @objc private func checkUpdates() { state.showWindow?(); state.updater.check(userAsked: true) }
    @objc private func open() { state.showWindow?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
