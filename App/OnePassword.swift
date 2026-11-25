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

    /// One field of one item ("password" or "username"), revealed. Only the final line break `op` adds is removed.
    static func field(_ label: String, of id: String) async throws -> String {
        let out = try await run(["item", "get", id, "--fields", "label=\(label)", "--reveal"])
        var text = String(decoding: out, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
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
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.wait()
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

    /// Items whose title or website shares a word (3+ letters) with the session's name come first, then A-Z.
    static func ranked(_ items: [Item], session: String) -> [Item] {
        let words = Set(session.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        func score(_ item: Item) -> Int {
            let hay = (item.title + " " + item.urls.joined(separator: " ")).lowercased()
            return words.filter { hay.contains($0) }.count
        }
        return items.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
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
                let list = model.shown
                if let item = list.first(where: { $0.id == model.selection }) ?? list.first {
                    self.pick(item, withUser: event.modifierFlags.contains(.option))
                }
                return nil
            default: return event
            }
        }
        Task { @MainActor in
            do {
                let items = OnePassword.ranked(try await OnePassword.list(), session: session)
                guard self.model === model else { return }
                model.items = items
                model.selection = items.first?.id
                model.status = items.isEmpty ? "No logins in 1Password" : nil
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
                .onChange(of: model.query) { _ in model.selection = model.shown.first?.id }
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
