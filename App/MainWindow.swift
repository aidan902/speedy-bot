import AppKit
import SwiftUI

extension Color {
    /// FM brand green, and the deep green it is paired with.
    static let fmGreen = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0x64 / 255)
    static let fmDeep = Color(red: 0x00 / 255, green: 0x4D / 255, blue: 0x19 / 255)
    /// The blue of a switched-on control in Control Center.
    static let controlBlue = Color(nsColor: .systemBlue)
}

/// A round icon that is the switch: blue with a white symbol when on, grey when off (the Control Center look).
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
                Circle().fill(isOn ? Color.controlBlue : Color.primary.opacity(emptyWhenOff ? 0.04 : 0.12))
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
                FeatureRow(symbol: "photo.on.rectangle.angled", title: "Paste screenshots into ChatGPT",
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
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        ShortcutRecorder(label: state.captureShortcutLabel,
                                         resetLabel: state.captureShortcut == nil ? nil : WindowCaptureController.defaultShortcut.label) { state.setCaptureShortcut($0) }
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
                Text("Version \(Updater.currentVersion)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Speedy Bot") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 430)
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
            .saturation(state.active ? 1 : 0)
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
        case .hover: how = "rest the pointer on ChatGPT"
        case .doubleClick: how = "double-click in ChatGPT"
        case .tripleClick: how = "triple-click in ChatGPT"
        case .shortcut: how = "press your shortcut"
        }
        return "Take a screenshot, then \(how). It goes into the message box."
    }

    private var pasteOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text("Resting the pointer pastes a fresh screenshot. One that has waited longer only pastes when you double-click in ChatGPT.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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
            HStack {
                Text("Typing speed")
                Spacer()
                Picker("Typing speed", selection: $state.fastTyping) {
                    Text("Safe").tag(false)
                    Text("Fast").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
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

/// The window's contents, scrolling when they are taller than the screen (a 13-inch MacBook with every option open).
struct MainWindowContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView(.vertical) { MainView(state: state) }
            .frame(width: 430)
            .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 40)   // leave room for the title bar
            .fixedSize(horizontal: false, vertical: true)
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

@MainActor
final class MainWindowController {
    private let window: NSWindow
    private var resizeObserver: NSObjectProtocol?

    init(state: AppState) {
        // The hosting controller keeps the window exactly as tall as its contents as options open and close.
        let host = NSHostingController(rootView: MainWindowContent(state: state))
        host.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Speedy Bot"
        window.isReleasedWhenClosed = false
        // A window made this way starts at 1x32 and only takes the SwiftUI size on the first layout pass,
        // growing down and right from the same corner. Size it first, then centre.
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        window.center()
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

    static func snapshot(state: AppState, to url: URL) -> Bool {
        let host = NSHostingView(rootView: MainView(state: state).background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
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
