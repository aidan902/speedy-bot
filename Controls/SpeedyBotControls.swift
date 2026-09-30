import AppIntents
import AppKit
import SwiftUI
import WidgetKit

/// Control Center / menu bar control (macOS 26+): one switch that turns Speedy Bot on or off.
/// It only flips the shared master switch; the app does the work and hears about the change
/// through a Darwin notification.
@main
struct SpeedyBotControlsBundle: WidgetBundle {
    var body: some Widget {
        SpeedyBotToggleControl()
    }
}

enum SpeedyBotApp {
    /// The app that contains this extension: <app>/Contents/PlugIns/<this>.appex
    static var url: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var isRunning: Bool {
        SpeedyShared.bool(SpeedyShared.appRunningKey, default: false)
            && !NSRunningApplication.runningApplications(withBundleIdentifier: SpeedyShared.appBundleID).isEmpty
    }

    /// Start the app quietly (no window comes to the front) so that switching On actually does something.
    static func launchInBackground() {
        SpeedyShared.defaults.set(Date().timeIntervalSince1970, forKey: SpeedyShared.quietLaunchKey)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }
}

struct SpeedyBotToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SpeedyShared.controlKind, provider: Provider()) { isOn in
            ControlWidgetToggle("Speedy Bot", isOn: isOn, action: SetSpeedyBotEnabledIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "hare.fill" : "hare")
            }
        }
        .displayName("Speedy Bot")
        .description("Turn Speedy Bot on or off.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        /// On only when the switch is on AND the app is there to act on it.
        func currentValue() async throws -> Bool { SpeedyShared.isEnabled && SpeedyBotApp.isRunning }
    }
}

struct SetSpeedyBotEnabledIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Speedy Bot On or Off"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        SpeedyShared.isEnabled = value
        SpeedyShared.postChanged()
        if value, !SpeedyBotApp.isRunning { SpeedyBotApp.launchInBackground() }
        return .result()
    }
}
