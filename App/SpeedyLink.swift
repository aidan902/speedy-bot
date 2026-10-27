import Foundation

/// The actions a speedybot:// link can ask for. Parsing is kept apart from carrying out, so it can be checked
/// on its own. Only switching modes and showing the window are offered: nothing a link can ask for types,
/// pastes or sends anything.
enum SpeedyLink {
    enum Action: String, CaseIterable {
        /// Off, or back to whichever of On and Auto it was in before.
        case toggle
        case on, off, auto
        /// Back on, in whichever of On and Auto it was in before.
        case enable
        /// Just make sure Speedy Bot is running (a link starts it if it is not), changing nothing.
        case start
        case show
        case multiPing = "multiping"
    }

    private static let aliases: [String: Action] = [
        "disable": .off, "open": .show, "window": .show, "ping": .multiPing, "status": .start, "": .start,
    ]

    /// `speedybot://toggle`, `speedybot:toggle` and `speedybot:///toggle` all name the same action.
    static func action(of url: URL) -> Action? {
        guard url.scheme?.lowercased() == SpeedyShared.urlScheme else { return nil }
        var name = (url.host ?? "").lowercased()
        if name.isEmpty {
            let path = url.path.isEmpty ? (url.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "") : url.path
            name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        return Action(rawValue: name) ?? aliases[name]
    }
}

/// Proof that an action key really came from the keypad plugin. A Darwin notification says nothing about who posted
/// it, and sandboxed apps can post them too, so the plugin first writes a press file (the time, in milliseconds since
/// 1970) into a folder of Speedy Bot's that sandboxed apps cannot reach, then posts. An action runs only when its
/// file is there and fresh; the file is used up either way.
enum KeypadPress {
    static var folder: URL { AppState.stateFileURL.deletingLastPathComponent().appendingPathComponent("keypad", isDirectory: true) }

    /// `key`: the plugin's name for the key (type, capture, paste, pastesend).
    static func consume(_ key: String, in folder: URL = folder, now: Date = Date()) -> Bool {
        let url = folder.appendingPathComponent(key)
        // Only a plain file written by this user (never a link to something else).
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        let text = try? String(contentsOf: url, encoding: .utf8)
        try? FileManager.default.removeItem(at: url)
        guard let ms = text.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return false }
        let age = now.timeIntervalSince1970 - ms / 1000
        return age > -1 && age < 3
    }
}
