import AppKit
import SwiftUI

extension Color {
    /// FM brand green, and the deep green it is paired with.
    static let fmGreen = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0x64 / 255)
    static let fmDeep = Color(red: 0x00 / 255, green: 0x4D / 255, blue: 0x19 / 255)
    /// A switched-on control: the green of the app icon, between its light top (FM green) and deep bottom, so a white
    /// symbol on it stays readable.
    static let controlOn = Color(red: 0.11, green: 0.72, blue: 0.33)
}

/// A round icon that is the switch: green with a white symbol when on, grey when off (the Control Center look).
struct RoundToggle: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool
    var size: CGFloat = 32
    /// A check box: an empty ring when off, instead of a greyed-out tick that could be read as "ticked".
    var emptyWhenOff = false

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                Circle().fill(isOn ? Color.controlOn : Color.primary.opacity(emptyWhenOff ? 0.04 : 0.12))
                if emptyWhenOff && !isOn { Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5) }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .opacity(emptyWhenOff && !isOn ? 0 : 1)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(isOn ? "On. Click to turn off." : "Off. Click to turn on.")
    }
}

/// The small window: a master switch, one switch per feature, and the options under each.
struct MainView: View {
    @ObservedObject var state: AppState

    private let inset: CGFloat = 56   // options line up under the feature titles

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !state.accessibilityGranted { permissionCard }

            VStack(spacing: 0) {
                FeatureRow(symbol: "photo.on.rectangle.angled", title: "Paste screenshots into \(state.pasteTargetNames)",
                           detail: pasteDetail, isOn: $state.screenshotPaste)
                if state.screenshotPaste { pasteOptions }
                if state.screenshotPaste || state.saveScreenshots { normalActionOption }

                Divider().padding(.leading, inset)
                FeatureRow(symbol: "keyboard", title: "\(state.typingShortcutLabel) types into ScreenConnect",
                           detail: "In a remote session, \(state.typingShortcutLabel) types your copied text key by key. Works on login screens where paste does not. Esc stops it.",
                           isOn: $state.remoteTyping)
                if state.remoteTyping { typingOptions }

                Divider().padding(.leading, inset)
                FeatureRow(symbol: "macwindow.badge.plus", title: "\(state.captureShortcutLabel) captures the ScreenConnect window",
                           detail: "One press takes a screenshot of the whole session window, no dragging. It is then handled like any other screenshot. macOS asks for Screen Recording permission the first time.",
                           isOn: $state.captureWindow)
                if state.captureWindow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Shortcut")
                            Spacer()
                            ShortcutRecorder(label: state.captureShortcutLabel,
                                             resetLabel: state.captureShortcut == nil ? nil : WindowCaptureController.defaultShortcut.label) { state.setCaptureShortcut($0) }
                        }
                        HStack(spacing: 8) {
                            RoundToggle(symbol: "checkmark", label: "Multi-capture: load into the LLM, don't send", isOn: $state.multiCapture, size: 22, emptyWhenOff: true)
                            Text("Multi-capture: load into the LLM, don't send").lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        if state.multiCapture {
                            Text("Each \(state.captureShortcutLabel) capture goes straight into the message box of \(state.pasteTargetNames) and focus comes back to ScreenConnect, so you can gather several, then send them yourself.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset).padding(.trailing, 12).padding(.bottom, 12)
                }

                Divider().padding(.leading, inset)
                FeatureRow(symbol: "folder.badge.plus", title: "Save screenshots for documentation",
                           detail: "Every screenshot is also filed under SpeedyBot Documentation, in a folder named for the incident, as evidence or for internal and external write-ups.",
                           isOn: $state.saveScreenshots)
                if state.saveScreenshots { DocumentationRow(state: state, inset: inset) }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .disabled(!state.masterEnabled)
            .opacity(state.masterEnabled ? 1 : 0.55)

            HStack(spacing: 10) {
                RoundToggle(symbol: "checkmark", label: "Open Speedy Bot at login",
                            isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }), size: 22, emptyWhenOff: true)
                Text("Open Speedy Bot at login")
                Spacer()
            }
            if let note = state.loginItemNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            UpdateRow(state: state, updater: state.updater)

            HStack {
                Spacer()
                Button("Quit Speedy Bot") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(22)
        .frame(maxWidth: 740, alignment: .leading)
        .tint(.fmGreen)
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.fmGreen, Color(red: 0.07, green: 0.62, blue: 0.27)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "hare.fill").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .saturation(state.mode == .off ? 0 : 1)   // green unless Speedy Bot is Off
            VStack(alignment: .leading, spacing: 1) {
                Text("Speedy Bot").font(.title2.weight(.semibold))
                Text(statusText).font(.callout).foregroundStyle(state.active ? Color.fmGreen : Color.secondary)
            }
            Spacer()
            Picker("Speedy Bot", selection: $state.mode) {
                ForEach(MasterMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Auto: Speedy Bot only works while a ScreenConnect session is open.")
        }
    }

    private var statusText: String {
        switch state.mode {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return state.screenConnectOpen ? "On: a ScreenConnect session is open" : "Waiting for a ScreenConnect session"
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Speedy Bot presses ⌘V and types for you, and macOS only allows that for apps you approve. Turn on Speedy Bot under Privacy & Security > Accessibility.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { state.requestAccessibility() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pasteDetail: String {
        let how: String
        switch state.pasteTrigger {
        case .hover: how = "move the pointer onto \(state.pasteTargetNames)"
        case .doubleClick: how = "double-click in \(state.pasteTargetNames)"
        case .tripleClick: how = "triple-click in \(state.pasteTargetNames)"
        case .shortcut: how = "press your shortcut"
        }
        return "Take a screenshot, then \(how). It goes into the message box."
    }

    /// Grok's own app and the browsers that are installed, in priority order.
    private var installedPlaces: [String] {
        state.placePriority.filter { place in
            place == PasteTarget.appPlace || NSWorkspace.shared.urlForApplication(withBundleIdentifier: place) != nil
        }
    }

    private var pasteOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Paste into").fixedSize()
                ForEach(PasteTarget.allCases) { target in
                    HStack(spacing: 5) {
                        RoundToggle(symbol: "checkmark", label: target.title, isOn: Binding(
                            get: { state.pasteTargets.contains(target) },
                            set: { on in if on { state.pasteTargets.insert(target) } else { state.pasteTargets.remove(target) } }
                        ), size: 22, emptyWhenOff: true)
                        Text(target.title).lineLimit(1).fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }
            if state.pasteTargets.contains(.grok) {
                Text("Grok counts as the Grok app, or grok.com open in Safari, Chrome, Arc, Brave or Edge (there a screenshot is pasted and Return pressed).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if state.pasteTargets.count > 1 {
                PriorityRow(title: "Chat priority", items: state.chatPriority.filter(state.pasteTargets.contains), name: \.title) {
                    state.raisePriority($0, in: &state.chatPriority)
                }
            }
            if state.pasteTargets.contains(.grok) {
                PriorityRow(title: "Grok in", items: installedPlaces, name: PasteTarget.placeName) {
                    state.raisePriority($0, in: &state.placePriority)
                }
            }
            if state.pasteTargets.count > 1 || state.pasteTargets.contains(.grok) {
                Text("When more than one is open and no chat was just used (or Auto LLM is off), screenshots go to the first. ← moves one up.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                RoundToggle(symbol: "checkmark", label: "Auto LLM", isOn: $state.autoMCP, size: 22, emptyWhenOff: true)
                Text("Auto LLM: paste into the chat app the pointer was last in").lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            if state.autoMCP {
                Text("A screenshot goes to whichever of the ticked apps (\(state.pasteTargetNames)) the pointer was last over.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Paste when")
                Spacer()
                Picker("Paste when", selection: $state.pasteTrigger) {
                    ForEach(PasteTrigger.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if state.pasteTrigger == .hover {
                HStack(spacing: 8) {
                    RoundToggle(symbol: "checkmark", label: "Older screenshots need a double-click", isOn: $state.staleDoubleClick, size: 22, emptyWhenOff: true)
                    Text("After")
                    SecondsField(value: $state.staleAfterSeconds)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 48)
                        .disabled(!state.staleDoubleClick)
                    Text("seconds, double-click to paste").lineLimit(1)
                    Spacer(minLength: 0)
                }
                if state.staleDoubleClick {
                    Text("Moving onto the chat pastes a fresh screenshot. One that has waited longer only pastes when you double-click in it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                RoundToggle(symbol: "checkmark", label: "Auto-send screenshots", isOn: $state.autoSendFromSession, size: 22, emptyWhenOff: true)
                Text("Auto-send screenshots").lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            if state.autoSendFromSession {
                Text("With a ScreenConnect session in front and \(state.pasteTargetNames) open on the same desktop, a screenshot is pasted and sent straight away. No pointer move, no Return. Anywhere else, it is sent as soon as it is pasted; with Auto LLM on too, it goes straight into the chat you were last in, without moving there. Nothing is sent while you have something typed in the message box (Claude's box cannot be checked).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if state.pasteTrigger == .shortcut {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(label: state.pasteShortcut?.label ?? "Click to set", resetLabel: nil) { state.setPasteShortcut($0) }
                }
                Text("The shortcut is only taken over while a screenshot is waiting. A mouse button set to send a keystroke works too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset).padding(.trailing, 12).padding(.bottom, 10)
    }

    private var normalActionOption: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundToggle(symbol: "checkmark", label: "Also do my normal screenshot action", isOn: $state.keepNormalScreenshots, size: 22, emptyWhenOff: true)
                Text("Also do my normal screenshot action")
            }
            Text(state.keepNormalScreenshots
                 ? "Screenshots still save where they always do and still pop up in the corner. The paste waits for the saved file: about 5 seconds while the corner preview is on."
                 : "Off: screenshots go straight to the clipboard instead of being saved, so the paste is instant.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = state.screenshotNote {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset).padding(.trailing, 12).padding(.bottom, 12)
    }

    private var typingOptions: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Shortcut")
                Spacer()
                ShortcutRecorder(label: state.typingShortcutLabel,
                                 resetLabel: state.typingShortcut == nil ? nil : HotKeySpec.defaultLabel) { state.setTypingShortcut($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset).padding(.trailing, 12).padding(.bottom, 12)
    }
}

/// A whole-seconds field that edits a draft and commits a clamped value, so the number shown is the rule in force.
private struct SecondsField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...1800
    @State private var draft: Int?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("30", value: $draft, format: .number.grouping(.never))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            .onChange(of: value) { draft = $0 }
            .onAppear { draft = value }
            // Clicking elsewhere or switching apps does not end editing on macOS, so commit then too.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commit() }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let clamped = min(max(draft ?? value, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        draft = clamped
    }
}

/// The pages of the window.
enum MainPage: String, CaseIterable, Identifiable {
    case switches, multiPing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .switches: return "Speedy Bot"
        case .multiPing: return "Multi Ping"
        }
    }
    var symbol: String {
        switch self {
        case .switches: return "hare.fill"
        case .multiPing: return "dot.radiowaves.left.and.right"
        }
    }
}

/// The window: a sidebar with the pages on the left, the chosen page on the right (scrolling when it is
/// taller than the window).
struct MainWindowContent: View {
    @ObservedObject var state: AppState

    /// The size Typeless opens at; the tech's own size is remembered after that.
    static let defaultSize = NSSize(width: 1080, height: 750)
    static let minSize = NSSize(width: 840, height: 560)

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state)
            Divider()
            ScrollView(.vertical) {
                Group {
                    switch state.page {
                    case .switches: MainView(state: state)
                    case .multiPing: MultiPingView(state: state.multiPing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }
}

private struct Sidebar: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [.fmGreen, Color(red: 0.07, green: 0.62, blue: 0.27)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "hare.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                .saturation(state.mode == .off ? 0 : 1)   // green unless Speedy Bot is Off
                Text("Speedy Bot").font(.headline)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            ForEach(MainPage.allCases) { page in
                Button { state.page = page } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(state.page == page ? Color.primary.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text(state.mode.title).font(.caption.weight(.semibold)).foregroundStyle(state.active ? Color.fmGreen : Color.secondary)
                Text(state.mode == .auto
                     ? (state.screenConnectOpen ? "A ScreenConnect session is open" : "Waiting for a ScreenConnect session")
                     : (state.mode == .on ? "Working everywhere" : "Not doing anything"))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Text("Version \(Updater.currentVersion)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Automatic updates: on/off, beta versions, a manual check, and what the updater last found.
private struct UpdateRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundToggle(symbol: "checkmark", label: "Update automatically", isOn: $state.autoUpdate, size: 22, emptyWhenOff: true)
                Text("Update automatically")
                Spacer()
                Button("Check Now") { updater.check(userAsked: true) }.controlSize(.small)
            }
            HStack(spacing: 10) {
                RoundToggle(symbol: "checkmark", label: "Include beta versions", isOn: $state.betaUpdates, size: 22, emptyWhenOff: true)
                Text("Include beta versions")
                Spacer()
            }
            if !updater.status.isEmpty {
                Text(updater.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Incident number field and the folder the screenshots go to.
private struct DocumentationRow: View {
    @ObservedObject var state: AppState
    let inset: CGFloat
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Incident")
                TextField(Incident.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit { commit() }
                    .onChange(of: editing) { isEditing in if !isEditing { commit() } }
                    .onChange(of: draft) { text in if text != state.incident { state.incidentDraft = text } }
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folderText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Open") { state.openDocsFolder() }.controlSize(.small)
                Button("Change…") { state.chooseDocsRoot() }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset).padding(.trailing, 12).padding(.bottom, 12)
        .onAppear { draft = state.incident }
        .onChange(of: state.incident) { draft = $0 }
    }

    private var folderText: String {
        let home = NSHomeDirectory()
        let path = Documentation.folder(root: state.docsRoot, incident: state.incident).path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func commit() {
        state.setIncident(draft)
        draft = state.incident
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundToggle(symbol: symbol, label: title, isOn: $isOn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

/// The one window of the app.
@MainActor
final class MainWindowController {
    private let window: NSWindow
    private var resizeObserver: NSObjectProtocol?

    init(state: AppState) {
        let host = NSHostingController(rootView: MainWindowContent(state: state))
        host.sizingOptions = [.minSize]
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Speedy Bot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = MainWindowContent.minSize
        // Typeless-sized, or as big as a small screen allows; the size the tech drags it to is remembered.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setContentSize(NSSize(width: min(MainWindowContent.defaultSize.width, visible.width - 40),
                                     height: min(MainWindowContent.defaultSize.height, visible.height - 60)))
        window.center()
        window.setFrameAutosaveName("SpeedyBotMain")
        // AppKit does not pull a window back when it grows past the bottom of the screen.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, let visible = window.screen?.visibleFrame else { return }
                var origin = window.frame.origin
                guard origin.y < visible.minY else { return }
                origin.y = min(visible.minY, visible.maxY - window.frame.height)   // taller than the screen: pin the top
                window.setFrameOrigin(origin)
            }
        }
    }

    /// Draws one page at the window's standard size without showing anything (for the README and checks).
    @MainActor static func snapshot(state: AppState, page: MainPage, to url: URL) -> Bool {
        state.page = page
        let host = NSHostingView(rootView: MainWindowContent(state: state).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: MainWindowContent.defaultSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A priority order as a row: "1 Grok  ← 2 ChatGPT  ← 3 Claude"; the arrow moves that entry up one place.
private struct PriorityRow<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let name: (Item) -> String
    let raise: (Item) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fixedSize()
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Button { raise(item) } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(.borderless).help("Move \(name(item)) up")
                }
                Text("\(index + 1) \(name(item))").lineLimit(1).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(index == 0 ? Color.controlOn.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}
