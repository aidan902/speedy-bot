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
        if !state.masterEnabled { name = "hare" }
        else if state.typing { name = "keyboard.fill" }
        else if state.armed { name = "photo.fill" }
        else { name = "hare.fill" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Speedy Bot")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = state.masterEnabled
            ? (state.armed ? "Speedy Bot: screenshot ready, move to ChatGPT" : "Speedy Bot is on")
            : "Speedy Bot is off"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(toggle(state.masterEnabled ? "Speedy Bot is On" : "Speedy Bot is Off", on: state.masterEnabled, #selector(toggleMaster)))
        menu.addItem(.separator())
        let shot = toggle("Paste screenshots into ChatGPT", on: state.screenshotPaste, #selector(toggleScreenshot))
        let type = toggle("⌘⇧V types into ScreenConnect", on: state.remoteTyping, #selector(toggleTyping))
        shot.isEnabled = state.masterEnabled
        type.isEnabled = state.masterEnabled
        let save = toggle("Save screenshots for documentation", on: state.saveScreenshots, #selector(toggleSave))
        save.isEnabled = state.masterEnabled
        menu.addItem(shot)
        menu.addItem(type)
        menu.addItem(save)
        if state.saveScreenshots {
            menu.addItem(action("Incident: " + (state.incident.isEmpty ? "not set" : state.incident) + "…", #selector(incident)))
            menu.addItem(action("Open Documentation Folder", #selector(openDocs)))
        }
        if !state.accessibilityGranted {
            menu.addItem(.separator())
            menu.addItem(action("Grant Accessibility Permission…", #selector(grant)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Speedy Bot…", #selector(open)))
        menu.addItem(action("Quit Speedy Bot", #selector(quit), key: "q"))
    }

    private func toggle(_ title: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let i = action(title, selector)
        i.state = on ? .on : .off
        return i
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleMaster() { state.masterEnabled.toggle() }
    @objc private func toggleScreenshot() { state.screenshotPaste.toggle() }
    @objc private func toggleTyping() { state.remoteTyping.toggle() }
    @objc private func toggleSave() { state.saveScreenshots.toggle() }
    @objc private func incident() { state.askForIncident() }
    @objc private func openDocs() { state.openDocsFolder() }
    @objc private func grant() { state.requestAccessibility() }
    @objc private func open() { state.showWindow?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
