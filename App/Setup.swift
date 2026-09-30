import AppKit
import SwiftUI

/// The first-run window: which chat app the tech uses, and every permission Speedy Bot will need, asked for
/// up front instead of one at a time later.
@MainActor
final class SetupStatus: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var screenshotFolder = false
    @Published private(set) var documents = false
    /// Screen Recording was asked for during this run: macOS only reports it granted after the app reopens.
    @Published private(set) var screenRecordingAsked = false

    private var timer: Timer?

    var screenshotFolderName: String { ScreencapturePrefs.screenshotFolder.lastPathComponent }

    func startWatching() {
        refresh(probeFolders: false)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(probeFolders: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() { timer?.invalidate(); timer = nil }

    /// `probeFolders`: listing a folder is what makes macOS ask for it, so it is only done on purpose.
    func refresh(probeFolders: Bool) {
        accessibility = Permissions.accessibilityTrusted
        screenRecording = CGPreflightScreenCaptureAccess()
        if probeFolders {
            screenshotFolder = Self.canList(ScreencapturePrefs.screenshotFolder)
            documents = Self.canList(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        }
    }

    private static func canList(_ url: URL?) -> Bool {
        guard let url else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    // MARK: asking

    func askAccessibility() {
        Permissions.requestAccessibilityPrompt()
        NSWorkspace.shared.open(Permissions.accessibilitySettingsURL)
    }

    func askScreenRecording() {
        screenRecordingAsked = true
        CGRequestScreenCaptureAccess()
    }

    func askScreenshotFolder() {
        screenshotFolder = Self.canList(ScreencapturePrefs.screenshotFolder)   // the listing itself brings up the question
    }

    func askDocuments() {
        documents = Self.canList(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    }

    /// Everything at once, in the order that reads best: the two folder questions (each waits for an answer),
    /// then Screen Recording, then Accessibility, which ends in System Settings.
    func askEverything() {
        if !screenshotFolder { askScreenshotFolder() }
        if !documents { askDocuments() }
        if !screenRecording { askScreenRecording() }
        if !accessibility { askAccessibility() }
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var status: SetupStatus
    let onDone: () -> Void

    private var chosenApp: Binding<PasteTarget> {
        Binding(get: { PasteTarget.allCases.first { state.pasteTargets.contains($0) } ?? .chatGPT },
                set: { state.pasteTargets = [$0] })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [.fmGreen, Color(red: 0.07, green: 0.62, blue: 0.27)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "hare.fill").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Speedy Bot").font(.title2.weight(.semibold))
                    Text("Two minutes now, then it just works.").font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Which chat app do you use?").font(.headline)
                HStack {
                    Picker("Chat app", selection: chosenApp) {
                        ForEach(PasteTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Screenshots paste themselves into it. You can tick more than one later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Permissions").font(.headline)
                    Spacer()
                    Button("Allow All") { status.askEverything() }
                }
                Text("macOS asks for each of these once. Blue means it's done.")
                    .font(.caption).foregroundStyle(.secondary)

                PermissionRow(granted: status.accessibility, title: "Accessibility",
                              detail: "Lets Speedy Bot press ⌘V and type for you. Turn on Speedy Bot in the list that opens.",
                              buttonTitle: status.accessibility ? nil : "Open Settings") { status.askAccessibility() }
                PermissionRow(granted: status.screenRecording || status.screenRecordingAsked, title: "Screen Recording",
                              detail: status.screenRecordingAsked && !status.screenRecording
                                ? "Asked. It counts once Speedy Bot is reopened."
                                : "For the one-press capture of the ScreenConnect window (⇧⌘2).",
                              buttonTitle: status.screenRecording || status.screenRecordingAsked ? nil : "Allow") { status.askScreenRecording() }
                PermissionRow(granted: status.screenshotFolder, title: "\(status.screenshotFolderName) folder",
                              detail: "Where your screenshots are saved, so Speedy Bot can pick them up.",
                              buttonTitle: status.screenshotFolder ? nil : "Allow") { status.askScreenshotFolder() }
                PermissionRow(granted: status.documents, title: "Documents folder",
                              detail: "For filing screenshots under SpeedyBot Documentation by incident.",
                              buttonTitle: status.documents ? nil : "Allow") { status.askDocuments() }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Text("You can come back to this from the menu bar icon: Set Up Permissions…")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .tint(.fmGreen)
        .onAppear { status.startWatching() }
        .onDisappear { status.stopWatching() }
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(granted ? Color.controlBlue : Color.primary.opacity(0.04))
                if !granted { Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5) }
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).opacity(granted ? 1 : 0)
            }
            .frame(width: 22, height: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let buttonTitle { Button(buttonTitle, action: action).controlSize(.small) }
        }
    }
}

@MainActor
final class SetupWindowController {
    private let window: NSWindow
    private let status = SetupStatus()

    init(state: AppState, onDone: @escaping () -> Void) {
        let host = NSHostingController(rootView: SetupView(state: state, status: status, onDone: onDone))
        host.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Set Up Speedy Bot"
        window.isReleasedWhenClosed = false
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        window.center()
    }

    /// Opens the window and, on a first run, puts every question up straight away.
    func show(askImmediately: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        status.refresh(probeFolders: false)
        if askImmediately {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [status] in
                MainActor.assumeIsolated { status.askEverything() }
            }
        }
    }

    func close() { window.close() }
}
