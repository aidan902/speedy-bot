import AppKit
import SwiftUI

/// The small window: a master switch, one switch per feature, and the permission the app needs.
struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: state.masterEnabled ? "hare.fill" : "hare")
                    .font(.system(size: 30))
                    .foregroundStyle(state.masterEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speedy Bot").font(.title2.weight(.semibold))
                    Text(state.masterEnabled ? "On" : "Off").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Speedy Bot", isOn: $state.masterEnabled)
                    .toggleStyle(.switch).controlSize(.large).labelsHidden()
            }

            if !state.accessibilityGranted {
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

            VStack(spacing: 0) {
                FeatureRow(symbol: "photo.on.rectangle.angled",
                           title: "Paste screenshots into ChatGPT",
                           detail: "Take a screenshot, then move the pointer onto ChatGPT. It pastes itself into the message box. Screenshots go to the clipboard instead of the Desktop while this is on.",
                           isOn: $state.screenshotPaste)
                Divider().padding(.leading, 44)
                FeatureRow(symbol: "keyboard",
                           title: "⌘⇧V types into ScreenConnect",
                           detail: "In a remote session, ⌘⇧V types your copied text key by key. Works on login screens where paste does not. Esc stops it.",
                           isOn: $state.remoteTyping)
                if state.remoteTyping {
                    Divider().padding(.leading, 44)
                    HStack {
                        Text("Typing speed").padding(.leading, 44)
                        Spacer()
                        Picker("Typing speed", selection: $state.fastTyping) {
                            Text("Safe").tag(false)
                            Text("Fast").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    }
                    .padding(.vertical, 8).padding(.trailing, 12)
                }
                Divider().padding(.leading, 44)
                FeatureRow(symbol: "folder.badge.plus",
                           title: "Save screenshots for documentation",
                           detail: "Every screenshot is also filed under SpeedyBot Documentation, in a folder named for the incident, as evidence or for internal and external write-ups.",
                           isOn: $state.saveScreenshots)
                if state.saveScreenshots {
                    Divider().padding(.leading, 44)
                    DocumentationRow(state: state)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            .disabled(!state.masterEnabled)
            .opacity(state.masterEnabled ? 1 : 0.55)

            Toggle("Open Speedy Bot at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            if let note = state.loginItemNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Speedy Bot") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// Incident number field and the folder the screenshots go to.
private struct DocumentationRow: View {
    @ObservedObject var state: AppState
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
        .padding(.leading, 44).padding(.trailing, 12).padding(.vertical, 10)
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
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 20).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(12)
    }
}

@MainActor
final class MainWindowController {
    private let window: NSWindow

    init(state: AppState) {
        let host = NSHostingView(rootView: MainView(state: state))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Speedy Bot"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setContentSize(host.fittingSize)
        window.center()
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
        if let host = window.contentView { window.setContentSize(host.fittingSize) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
