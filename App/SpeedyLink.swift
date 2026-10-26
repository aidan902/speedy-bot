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
