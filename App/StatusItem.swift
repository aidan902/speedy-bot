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
        default: item.button?.toolTip = state.armed ? "Speedy Bot: a screenshot is waiting to go into ChatGPT" : "Speedy Bot is on"
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
            toggle("Paste screenshots into ChatGPT", symbol: "photo.on.rectangle.angled", on: state.screenshotPaste, #selector(toggleScreenshot)),
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

    /// A feature switch: the same round blue icon as in the window, instead of a tick.
    private func toggle(_ title: String, symbol: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let i = action(title, selector)
        i.image = Self.roundIcon(symbol: symbol, on: on, emptyWhenOff: false)
        return i
    }

    /// One of several choices: a blue icon for the chosen one, an empty ring for the others.
    private func choice(_ title: String, symbol: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let i = action(title, selector)
        i.image = Self.roundIcon(symbol: symbol, on: on, emptyWhenOff: true)
        return i
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Drawn on demand, so it follows light and dark mode.
    private static func roundIcon(symbol: String, on: Bool, emptyWhenOff: Bool, size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if on {
                NSColor.systemBlue.setFill(); circle.fill()
            } else if emptyWhenOff {
                NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke(); circle.lineWidth = 1.2; circle.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.12).setFill(); circle.fill()
            }
            guard on || !emptyWhenOff,
                  let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: size * 0.48, weight: .semibold))?
                    .withSymbolConfiguration(.init(paletteColors: [on ? .white : .secondaryLabelColor])) else { return true }
            let g = glyph.size
            glyph.draw(in: NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2, width: g.width, height: g.height))
            return true
        }
        image.isTemplate = false
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
