import AppKit
import SwiftUI

/// 1Password on this Mac, through its command-line tool `op` with the 1Password app's CLI integration on (the app
/// asks for Touch ID or the account password; Speedy Bot never sees or stores that). Only item titles, usernames,
/// vaults and websites are listed; a password is fetched only for the item the tech picks, held in memory just long
/// enough to type it, and never logged, written or put on the clipboard.
enum OnePassword {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let username: String
        let vault: String
        let urls: [String]
    }

    enum Failure: Error {
        case notInstalled, integrationOff(String), cancelled, failed(String)

        var message: String {
            switch self {
            case .notInstalled: return "The 1Password command-line tool is not installed (brew install --cask 1password-cli)"
            case .integrationOff: return "In 1Password, turn on Settings > Developer > Integrate with 1Password CLI"
            case .cancelled: return "1Password was not unlocked"
            case .failed(let why): return "1Password: \(why)"
            }
        }
    }

    static var cliPath: String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Logins, passwords, servers and databases across every vault the account can see.
    static func list() async throws -> [Item] {
        let out = try await run(["item", "list", "--categories", "Login,Password,Server,Database", "--format", "json"])
        guard let rows = try? JSONSerialization.jsonObject(with: out) as? [[String: Any]] else { throw Failure.failed("unexpected answer") }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let vault = (row["vault"] as? [String: Any])?["name"] as? String ?? ""
            let urls = (row["urls"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
            return Item(id: id, title: row["title"] as? String ?? "(untitled)",
                        username: row["additional_information"] as? String ?? "", vault: vault, urls: urls)
        }
    }

    struct Secrets: Sendable { let username: String; let password: String }

    /// The username and password of one item, exactly as stored (read from the item's JSON, not from `--fields`,
    /// whose CSV output quotes a value with a comma or a quote in it). The item's own password field (purpose
    /// PASSWORD, or the field with id "password") is used; an item with no such field but exactly one field labelled
    /// "password" uses that one, and one with several is refused rather than guessed.
    static func secrets(of id: String) async throws -> Secrets {
        let out = try await run(["item", "get", id, "--format", "json", "--reveal"])
        guard let item = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { throw Failure.failed("unexpected answer") }
        let fields = item["fields"] as? [[String: Any]] ?? []
        func pick(purpose: String, id: String) throws -> String {
            if let f = fields.first(where: { ($0["purpose"] as? String) == purpose }) ?? fields.first(where: { ($0["id"] as? String) == id }) {
                return f["value"] as? String ?? ""
            }
            let labelled = fields.filter { ($0["label"] as? String)?.lowercased() == id }
            if labelled.count > 1 { throw Failure.failed("that item has more than one \(id) field") }
            return labelled.first?["value"] as? String ?? ""
        }
        return Secrets(username: try pick(purpose: "USERNAME", id: "username"), password: try pick(purpose: "PASSWORD", id: "password"))
    }

    /// Runs `op` off the main thread. Its output is returned, never logged; its error text is only matched.
    private static func run(_ arguments: [String]) async throws -> Data {
        guard let path = cliPath else { throw Failure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["OP_FORMAT"] = nil
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: Failure.failed("could not start the command-line tool"))
                    return
                }
                // Read both pipes while it runs (a big vault list fills a pipe's buffer).
                final class Box: @unchecked Sendable { var data = Data() }
                let outBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                group.wait()   // the reader is done before its data is used
                let outData = outBox.data
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                    return
                }
                let message = String(decoding: errData, as: UTF8.self).lowercased()
                if message.contains("integration") || message.contains("no accounts configured") || message.contains("connecting to desktop app")
                    || message.contains("app is not running") {
                    continuation.resume(throwing: Failure.integrationOff(message))
                } else if message.contains("cancel") || message.contains("dismissed") || message.contains("authorization") {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    SpeedyShared.log.notice("1Password command failed (status \(process.terminationStatus))")
                    continuation.resume(throwing: Failure.failed("the command-line tool could not answer"))
                }
            }
        }
    }

    /// Words in a ScreenConnect window title that say nothing about the machine (the tech's own ScreenConnect login
    /// must never come first because of them).
    static let titleNoise: Set<String> = ["screenconnect", "connectwise", "control", "connected", "connecting", "disconnected",
                                          "session", "sessions", "remote", "access", "support", "meeting", "guest", "host", "client", "the"]

    /// Items whose title or website shares a word (3+ letters, not ScreenConnect's own) with the session's name come
    /// first, then A-Z. `matched`: whether the first one shares such a word (only then is it chosen in advance).
    static func ranked(_ items: [Item], session: String) -> (items: [Item], matched: Bool) {
        let words = Set(session.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !titleNoise.contains($0) })
        func score(_ item: Item) -> Int {
            let hay = (item.title + " " + item.urls.joined(separator: " ")).lowercased()
            return words.filter { hay.contains($0) }.count
        }
        let sorted = items.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return (sorted, sorted.first.map { score($0) > 0 } ?? false)
    }
}

/// The search box over the 1Password vault that the keypad's Password key opens over a ScreenConnect session.
/// Return types the password into the session; Option-Return types the username, Tab, then the password. Esc closes.
@MainActor
final class PasswordPicker: NSObject, NSWindowDelegate {
    final class Model: ObservableObject {
        @Published var items: [OnePassword.Item] = []
        @Published var query = ""
        @Published var selection: OnePassword.Item.ID?
        @Published var status: String? = "Waiting for 1Password…"
        let session: String

        init(session: String) { self.session = session }

        var shown: [OnePassword.Item] {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return items }
            return items.filter { item in
                [item.title, item.username, item.vault, item.urls.joined(separator: " ")].contains { $0.lowercased().contains(q) }
            }
        }
    }

    private var panel: NSPanel?
    private var model: Model?
    private var keyMonitor: Any?
    /// What a pick does: (item, with username).
    private var onPick: ((OnePassword.Item, Bool) -> Void)?

    func show(session: String, onPick: @escaping (OnePassword.Item, Bool) -> Void) {
        close()
        let model = Model(session: session)
        self.model = model
        self.onPick = onPick
        let view = PasswordPickerView(model: model, pick: { [weak self] item, withUser in self?.pick(item, withUser: withUser) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Type a 1Password password"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Arrows move the selection and Esc closes, wherever the keyboard is in the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, let model = self.model else { return event }
            switch Int(event.keyCode) {
            case 53: self.close(); return nil   // Esc
            case 125, 126:                       // down, up
                let list = model.shown
                guard !list.isEmpty else { return nil }
                let i = list.firstIndex { $0.id == model.selection } ?? -1
                let next = event.keyCode == 125 ? min(i + 1, list.count - 1) : max(i - 1, 0)
                model.selection = list[next].id
                return nil
            case 36, 76:                         // Return, Enter
                let withUser = event.modifierFlags.contains(.option)
                // A click on a row selects it a moment later: let that land before reading the selection.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        guard self.model === model else { return }
                        let list = model.shown
                        let searched = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
                        if let item = list.first(where: { $0.id == model.selection }) ?? (searched ? list.first : nil) {
                            self.pick(item, withUser: withUser)
                        } else {
                            NSSound.beep()   // nothing chosen yet
                        }
                    }
                }
                return nil
            default: return event
            }
        }
        Task { @MainActor in
            do {
                let ranked = OnePassword.ranked(try await OnePassword.list(), session: session)
                guard self.model === model else { return }
                model.items = ranked.items
                // Chosen in advance only when it matches this session; otherwise the tech picks or searches.
                model.selection = ranked.matched ? ranked.items.first?.id : nil
                model.status = ranked.items.isEmpty ? "No logins in 1Password" : nil
            } catch let failure as OnePassword.Failure {
                guard self.model === model else { return }
                model.status = failure.message
            } catch {
                model.status = "1Password could not be read"
            }
        }
    }

    private func pick(_ item: OnePassword.Item, withUser: Bool) {
        let onPick = self.onPick
        close()
        onPick?(item, withUser)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        model = nil
        onPick = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel = nil
        model = nil
        onPick = nil
    }
}

private struct PasswordPickerView: View {
    @ObservedObject var model: PasswordPicker.Model
    let pick: (OnePassword.Item, Bool) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search 1Password", text: $model.query)
                .textFieldStyle(.roundedBorder).font(.title3)
                .focused($searchFocused)
                .onChange(of: model.query) { _ in
                    // Typing a search chooses its first result; clearing it chooses nothing.
                    model.selection = model.query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.shown.first?.id
                }
            if let status = model.status {
                Text(status).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(model.shown, selection: $model.selection) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.medium))
                            Text([item.username, item.vault].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { pick(item, NSEvent.modifierFlags.contains(.option)) }
                    }
                    .onChange(of: model.selection) { id in if let id { proxy.scrollTo(id) } }
                }
            }
            Text("Return types the password into \(model.session.isEmpty ? "the session" : model.session).  ⌥Return types the username, Tab, then the password.  Esc closes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 14)
        .onAppear { searchFocused = true }
    }
}
