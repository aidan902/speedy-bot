import Foundation
import os

/// State shared between the (unsandboxed) app and the (sandboxed) Control Center extension.
enum SpeedyShared {
    /// macOS-style app group: <TeamID>.<anything>. Needs no provisioning profile.
    /// Comes from Info.plist (SBAppGroup = $(SB_GROUP_ID)) so app, extension and entitlements can never disagree.
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "SBAppGroup") as? String ?? "SRPFLCC723.net.fm.speedybot"

    /// Master switch. This is the one the Control Center control flips.
    static let enabledKey = "enabled"
    static let screenshotPasteKey = "screenshotPaste"
    static let remoteTypingKey = "remoteTyping"
    static let fastTypingKey = "fastTyping"
    static let saveScreenshotsKey = "saveScreenshots"
    static let incidentKey = "incident"
    static let docsFolderKey = "docsFolder"
    /// Leave the system's screenshot behaviour alone (saved file, corner preview) and pick the saved file up instead.
    static let keepNormalScreenshotsKey = "keepNormalScreenshots"
    /// What makes an armed screenshot paste into ChatGPT: "hover", "doubleClick", "tripleClick" or "shortcut".
    static let pasteTriggerKey = "pasteTrigger"
    /// Which chat apps a screenshot may be pasted into ("chatGPT", "claude", "grok").
    static let pasteTargetsKey = "pasteTargets"
    /// A screenshot taken while in a ScreenConnect session is pasted into the chat and sent, with no trigger.
    static let autoSendFromSessionKey = "autoSendFromSession"
    /// The first-run setup window has been dismissed.
    static let setupDoneKey = "setupDone"
    /// "on", "off" or "auto" (only while a ScreenConnect session is open). `enabled` mirrors "not off" for the control.
    static let modeKey = "mode"
    /// In the pointer-rest mode: a screenshot older than this many seconds needs a double-click in ChatGPT instead.
    static let staleDoubleClickKey = "staleDoubleClick"
    static let staleAfterKey = "staleAfterSeconds"
    /// One shortcut captures the whole ScreenConnect session window.
    static let captureWindowKey = "captureWindow"
    /// Install new versions by themselves; and whether beta versions count.
    static let autoUpdateKey = "autoUpdate"
    static let betaUpdatesKey = "betaUpdates"
    /// Set just before an update relaunches the app, so the new copy can say it was updated.
    static let updatedToKey = "updatedTo"
    /// True while the app process is alive (set at launch, cleared on quit), so the control can show the truth.
    static let appRunningKey = "appRunning"
    static let appBundleID = "net.fm.speedybot"
    /// Time stamp the control writes just before it starts the app, so that launch stays in the background.
    static let quietLaunchKey = "quietLaunchAt"

    /// Darwin notification posted by whichever side changes a value.
    static let changedNotification = groupID + ".changed"
    /// Posted by a second copy of the app so the running one shows its window.
    static let showWindowNotification = groupID + ".showWindow"
    /// Kind string of the Control Center control.
    static let controlKind = "net.fm.speedybot.toggle"

    static let log = Logger(subsystem: "net.fm.speedybot", category: "app")

    static var defaults: UserDefaults {
        UserDefaults(suiteName: groupID) ?? .standard
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    static var isEnabled: Bool {
        get { bool(enabledKey, default: true) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }

    static func postChanged() { post(changedNotification) }
}
