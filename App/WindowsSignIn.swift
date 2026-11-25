import AppKit
import Carbon.HIToolbox

/// What the Password key's search learned from the session window: the sites a browser shows there, and a note
/// about a Windows sign-in, admin or lock screen when one is showing instead.
struct PageReading: Sendable {
    var hosts: [String]
    var windowsNote: String?
}

/// A Windows sign-in screen, admin prompt (User Account Control) or lock screen, read off the session window.
/// Only used when no web address is on the screen. Read from the boxes' grey placeholder words ("User name",
/// "Password", "PIN") and the words Windows puts around them.
enum WindowsPrompt: Equatable, Sendable {
    /// The sign-in screen. `userBox`: a User name box is showing (Other user), with the keyboard in it.
    case signIn(userBox: Bool)
    /// User Account Control asking for an administrator's user name and password.
    case adminPrompt(userBox: Bool)
    /// The picture with the clock: the sign-in boxes are not showing yet.
    case lockScreen
    /// "Press Ctrl+Alt+Delete to unlock": a key press cannot get past it.
    case ctrlAltDel
    /// Windows wants a PIN, not a password.
    case pin

    /// Letters and digits only, lower-case: OCR spacing and punctuation vary.
    private static func squash(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    static func read(_ lines: [SessionProbe.Line]) -> WindowsPrompt? {
        let squashed = lines.map { squash($0.text) }
        func box(_ word: String) -> Bool { squashed.contains(word) }
        func says(_ words: String) -> Bool { squashed.contains { $0.contains(words) } }
        let userBox = box("username")
        let passwordBox = box("password")
        if says("ctrlaltdelete") || says("ctrlaltdel") { return .ctrlAltDel }
        if (says("useraccountcontrol") || says("doyouwanttoallowthisapp") || says("enteranadminusername")), passwordBox {
            return .adminPrompt(userBox: userBox)
        }
        let signInWords = says("signinoptions") || box("otheruser") || says("signinto") || says("iforgotmypassword")
            || says("iforgotmypin") || says("howdoisignintoanotherdomain") || says("resetpassword")
        if box("pin"), !passwordBox, signInWords { return .pin }
        if passwordBox, signInWords { return .signIn(userBox: userBox) }
        let clock = lines.contains { $0.text.trimmingCharacters(in: .whitespaces).range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil }
        let date = squashed.contains { line in weekdays.contains { line.hasPrefix($0) } }
        if clock, date, !passwordBox, !userBox { return .lockScreen }
        return nil
    }

    /// Shown in the search box, so the tech knows what one press will do.
    var note: String {
        switch self {
        case .signIn(true): return "Windows sign-in: types .\\user (this PC's own account), Tab, the password, then Enter"
        case .signIn(false): return "Windows sign-in: types the password, then Enter"
        case .adminPrompt(true): return "Windows admin prompt: types .\\user, Tab, the password, then Enter"
        case .adminPrompt(false): return "Windows admin prompt: types the password, then Enter"
        case .lockScreen: return "Windows lock screen: woken first, then signed in"
        case .ctrlAltDel: return "Windows wants Ctrl+Alt+Delete first (ScreenConnect's button)"
        case .pin: return "Windows is asking for a PIN, not a password"
        }
    }

    enum Typing: Equatable { case text(String), refuse(String) }

    /// What one press types here, or why nothing is typed.
    func typing(username: String, password: String) -> Typing {
        switch self {
        case .signIn(true), .adminPrompt(true):
            // With the keyboard in the User name box, a password typed alone would show there in plain text.
            guard !username.isEmpty else { return .refuse("Windows wants a user name and that login has none. Nothing was typed") }
            return .text(Self.localAccount(username) + "\t" + password + "\n")
        case .signIn(false), .adminPrompt(false):
            return .text(password + "\n")
        case .lockScreen:
            return .refuse("Could not get past the Windows lock screen. Click it once in the session, then press Password again")
        case .ctrlAltDel:
            return .refuse("Windows wants Ctrl+Alt+Delete first. Use ScreenConnect's Ctrl+Alt+Del, then press Password again")
        case .pin:
            return .refuse("Windows is asking for a PIN. Choose Sign-in options and the password, then press Password again")
        }
    }

    /// A plain user name ("LocalAdmin") as this PC's own account (".\LocalAdmin"), not the domain's. A name that
    /// already says where it belongs ("CORP\jsmith", "jsmith@example.edu") is typed as saved.
    static func localAccount(_ name: String) -> String {
        name.contains("\\") || name.contains("@") ? name : ".\\" + name
    }

    /// A bare Shift tap: it lifts the lock screen picture and types nothing anywhere.
    static func wake() {
        let source = TextTyper.makeSource()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: false) else { return }
        down.flags = .maskShift
        up.flags = []
        down.post(tap: .cgSessionEventTap)
        usleep(40_000)
        up.post(tap: .cgSessionEventTap)
    }
}

/// How a pick is typed. `auto` (Return, or the Password key again): on a Windows sign-in or admin prompt whatever the
/// screen asks for, then Enter; elsewhere the password. The others are the box's buttons (⌥Return is userAndPassword).
enum PickKind: String, Sendable {
    case auto, userAndPassword, passwordOnly, userOnly

    /// What one pick types. `prompt`: the Windows screen showing in the session (nil anywhere else).
    func text(username: String, password: String, prompt: WindowsPrompt?) -> WindowsPrompt.Typing {
        // A lock screen still up, Ctrl+Alt+Delete or a PIN: nothing can be typed, whichever button.
        if let prompt, [.lockScreen, .ctrlAltDel, .pin].contains(prompt) { return prompt.typing(username: username, password: password) }
        let windows = prompt != nil
        let userBox = prompt == .signIn(userBox: true) || prompt == .adminPrompt(userBox: true)
        let enter = windows ? "\n" : ""
        func user() -> String { windows ? WindowsPrompt.localAccount(username) : username }
        switch self {
        case .auto:
            return prompt?.typing(username: username, password: password) ?? .text(password)
        case .userAndPassword:
            guard !username.isEmpty else { return .refuse("That login has no username. Use Password") }
            return .text(user() + "\t" + password + enter)
        case .passwordOnly:
            // The keyboard is in Windows' User name box: the password would show there in plain text.
            if userBox { return .refuse("Windows is showing a User name box, where a password would show in plain text. Use User + Password") }
            return .text(password + enter)
        case .userOnly:
            guard !username.isEmpty else { return .refuse("That login has no username") }
            return .text(user())
        }
    }
}

/// Which 1Password login the tech picked on which machine (the ScreenConnect session's name), kept on this Mac so
/// it comes first next time there, and is suggested on machines whose names start the same (LAB-ROOM12,
/// LAB-LOBBY). Only the item's id is kept, never a password.
enum PickMemory {
    private static let key = "passwordPicksByMachine"
    private static let keep = 500

    struct Pick: Sendable { let id: String; let at: Double }

    /// "ScreenConnect - LAB-ROOM12 - Connected" -> "LAB-ROOM12".
    static func machine(fromTitle title: String) -> String? {
        var parts = title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = parts.first?.lowercased(), first == "screenconnect" || first == "connectwise control" { parts.removeFirst() }
        if let last = parts.last?.lowercased(), ["connected", "connecting", "reconnecting", "disconnected"].contains(last) { parts.removeLast() }
        let name = parts.joined(separator: " - ").uppercased()
        return name.isEmpty ? nil : name
    }

    /// Names that start this way say nothing about whose machine it is.
    private static let generic: Set<String> = ["DESKTOP", "LAPTOP", "WIN", "WINDOWS", "PC", "USER", "WORKSTATION", "SURFACE",
                                               "DELL", "HP", "LENOVO", "ACER", "ASUS", "MAC", "MACBOOK", "IMAC", "ADMIN", "OWNER", "NEW"]

    /// "LAB-ROOM12" -> "LAB"; nil for a name with no separator, or a generic start (DESKTOP-4F2K9).
    static func prefix(of machine: String) -> String? {
        guard let cut = machine.firstIndex(where: { $0 == "-" || $0 == "_" || $0 == " " }) else { return nil }
        let start = String(machine[..<cut]).uppercased()
        guard start.count >= 2, !start.allSatisfy(\.isNumber), !generic.contains(start) else { return nil }
        return start
    }

    /// The login to choose first on `machine`, and the note saying why.
    static func choose(from picks: [String: Pick], machine: String) -> (id: String, note: String)? {
        if let exact = picks[machine] { return (exact.id, "Used last time on \(machine)") }
        guard let start = prefix(of: machine) else { return nil }
        let same = picks.filter { $0.key != machine && prefix(of: $0.key) == start }.max { $0.value.at < $1.value.at }
        return same.map { ($0.value.id, "Used on \($0.key) (same name start)") }
    }

    static func recall(machine: String) -> (id: String, note: String)? { choose(from: load(), machine: machine) }

    static func remember(itemID: String, machine: String) {
        var picks = load()
        picks[machine] = Pick(id: itemID, at: Date().timeIntervalSince1970)
        if picks.count > keep {
            for old in picks.sorted(by: { $0.value.at < $1.value.at }).prefix(picks.count - keep) { picks[old.key] = nil }
        }
        SpeedyShared.defaults.set(picks.mapValues { ["id": $0.id, "at": $0.at] as [String: Any] }, forKey: key)
    }

    private static func load() -> [String: Pick] {
        let raw = SpeedyShared.defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        return raw.compactMapValues { d in (d["id"] as? String).map { Pick(id: $0, at: d["at"] as? Double ?? 0) } }
    }
}
