import AppKit
import SwiftUI

/// The Multi Ping page: the remote machine's network, the addresses to reach, the command, and the button
/// that opens one PowerShell window per address inside the ScreenConnect session.
struct MultiPingView: View {
    @ObservedObject var state: MultiPingState
    @State private var showUniFiSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            remoteCard
            runCard
        }
        .padding(22)
        .frame(maxWidth: 780, alignment: .leading)
        .tint(.fmGreen)
        .onAppear { state.startWatchingSessions() }
        .onDisappear { state.stopWatchingSessions() }
        .sheet(isPresented: $showUniFiSettings) { UniFiSettingsSheet(state: state) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.fmGreen, Color(red: 0.07, green: 0.62, blue: 0.27)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Multi Ping").font(.title2.weight(.semibold))
                Text("Ping several devices from the remote machine, each in its own PowerShell window. Type it here; Speedy Bot sends it through the ScreenConnect session.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: the remote machine

    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote machine").font(.headline)
                Spacer()
                sessionPicker
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(state.probing ? "Reading…" : "Read from session") { state.readFromSession() }
                    .disabled(!(state.session?.connected ?? false) || state.busy || state.probing)
                    .help("Opens a PowerShell window in the session that prints the machine's address, network size and gateway, and reads the answer back.")
                Text(state.probeStatus.isEmpty
                     ? "Types one PowerShell line into the session and reads the answer back. Or type the address in yourself."
                     : state.probeStatus)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 14) {
                field("IP address") { TextField("172.16.37.46", text: $state.remoteIP).frame(width: 140) }
                field("Network size") {
                    Picker("Network size", selection: $state.prefix) {
                        ForEach(Array((8...30).reversed()), id: \.self) { p in
                            Text("/\(p)  ·  \(IPv4.mask(prefix: p).description)").tag(p)
                        }
                    }
                    .labelsHidden().frame(width: 210)
                }
                field("Gateway") { TextField("optional", text: $state.gateway).frame(width: 130) }
                Spacer(minLength: 0)
            }
            .textFieldStyle(.roundedBorder)
            if let summary = state.networkSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "network").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(unifiLine).fixedSize(horizontal: false, vertical: true)
                    Text(unifiDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(state.unifiBusy ? "Looking up…" : "Look Up") { state.lookUpUniFi() }
                    .disabled(state.unifiBusy || state.baseIP == nil)
                Button("Settings…") { showUniFiSettings = true }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var sessionPicker: some View {
        if state.sessions.isEmpty {
            Label("No ScreenConnect session is open", systemImage: "display.trianglebadge.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
        } else if state.sessions.count == 1 {
            Label(state.sessions[0].label, systemImage: "display").font(.callout)
                .foregroundStyle(state.sessions[0].connected ? Color.primary : Color.secondary)
        } else {
            Picker("Session", selection: Binding(get: { state.session?.windowID ?? 0 }, set: { state.selectedSession = $0 })) {
                ForEach(state.sessions) { s in Text(s.label).tag(s.windowID) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private var unifiLine: String {
        if let found = state.unifi { return "UniFi: " + found.summary }
        if !state.unifiStatus.isEmpty { return "UniFi: " + state.unifiStatus }
        return state.unifiHasKey ? "UniFi: which site, switch and port this machine is on" : "UniFi: not set up"
    }

    private var unifiDetail: String {
        if let found = state.unifi {
            if let c = found.client {
                var bits = ["MAC \(c.mac)"]
                if let name = c.displayName { bits.append(name) }
                if let network = c.network { bits.append("network \(network)") }
                return bits.joined(separator: " · ") + " · from \(state.unifiConfig.host)"
            }
            return "from \(state.unifiConfig.host)"
        }
        return state.unifiHasKey
            ? "Look Up asks \(state.unifiConfig.host) about the address above. Reading the address from the session does it by itself."
            : "Add the controller and an API key under Settings… and Speedy Bot notes the site, switch and port of the machine you are in."
    }

    // MARK: what to run

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to run").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                field("Command") {
                    Picker("Command", selection: $state.command) {
                        ForEach(PingCommand.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 320)
                }
                if state.command.needsPort {
                    field("Port") { IntField(value: $state.port, range: 1...65535, placeholder: "443").frame(width: 72) }
                }
                Spacer(minLength: 0)
            }
            if state.command == .custom {
                TextField("ping -t -l 1400 {ip}     ({ip} is where each address goes)", text: $state.custom)
                    .font(.system(.body, design: .monospaced))
            }
            field("Devices") {
                TextField(".1  .3  .5  .9", text: $state.targetsText, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(.body, design: .monospaced))
            }
            Text("Only the end of each address: .1, or .3 .5 .9, or .36.200 for the other half of a /23. Full addresses and ranges (.10-.20) work too.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = state.parsed.note { Text(note).font(.caption).foregroundStyle(.orange) }
            preview
            HStack(spacing: 12) {
                Button(action: { state.send() }) { Text(sendTitle).frame(minWidth: 240) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                if state.busy { Button("Stop") { state.stop() }.help("Esc does the same.") }
                Spacer()
                Toggle("Slow remote", isOn: $state.slowRemote).toggleStyle(.checkbox)
                    .help("Doubles the pauses while windows open, for a machine that takes its time.")
            }
            HStack(spacing: 8) {
                Text("Open each window through")
                Picker("Open each window through", selection: $state.openVia) {
                    ForEach(OpenVia.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text(state.openerNote).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if !state.status.isEmpty {
                Text(state.status).font(.callout).foregroundStyle(state.busy ? Color.fmGreen : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var preview: some View {
        let targets = state.targets
        if !targets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let ip = t.ip {
                            Text(ip.description).font(.system(.body, design: .monospaced)).frame(width: 130, alignment: .leading)
                            Text(state.line(for: t)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if !t.insideNetwork { Text("outside /\(state.prefix)").font(.caption).foregroundStyle(.orange) }
                            if let note = state.unifiNote(for: t) { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        } else {
                            Text(t.input).font(.system(.body, design: .monospaced)).foregroundStyle(.red).frame(width: 130, alignment: .leading)
                            Text(t.problem ?? "").font(.caption).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sendTitle: String {
        let n = state.ready.count
        guard let session = state.session else { return "Open PowerShell windows (no session open)" }
        if !session.connected { return "\(session.name) is not connected" }
        if n == 0 { return "Open PowerShell windows in \(session.name)" }
        return "Open \(n) PowerShell window\(n == 1 ? "" : "s") in \(session.name)"
    }

    private var canSend: Bool { (state.session?.connected ?? false) && !state.busy && !state.ready.isEmpty }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A whole-number field that edits a draft and commits a clamped value.
private struct IntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var placeholder: String
    @State private var draft: Int?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, value: $draft, format: .number.grouping(.never))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            .onChange(of: value) { draft = $0 }
            .onAppear { draft = value }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let clamped = min(max(draft ?? value, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        draft = clamped
    }
}

/// Where the UniFi controller is and the API key to use, kept in the keychain.
struct UniFiSettingsSheet: View {
    @ObservedObject var state: MultiPingState
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var trust: Bool
    @State private var apiKey = ""
    @State private var testResult = ""
    @State private var testing = false

    init(state: MultiPingState) {
        self.state = state
        _url = State(initialValue: state.unifiConfig.url)
        _trust = State(initialValue: state.unifiConfig.trustCertificate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UniFi controller").font(.headline)
            Text("Speedy Bot asks the controller which site, switch and port an address is on. It needs an API key: in UniFi Network open Settings › Control Plane › Integrations, create a key, and paste it here. The key is kept in your keychain and only ever sent to this controller.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://unifi.example.com", text: $url)
            SecureField(state.unifiHasKey ? "An API key is saved. Paste a new one to replace it" : "API key", text: $apiKey)
            Toggle("Trust this controller's certificate (for a self-signed controller)", isOn: $trust).toggleStyle(.checkbox)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(testing ? "Testing…" : "Test") { test() }
                    .disabled(testing || (apiKey.isEmpty && !state.unifiHasKey))
                if state.unifiHasKey {
                    Button("Forget Key") {
                        state.saveUniFi(config: UniFiConfig(url: url, trustCertificate: trust), apiKey: "")
                        testResult = "The key was removed from the keychain."
                    }
                }
                Text(testResult).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    state.saveUniFi(config: UniFiConfig(url: url, trustCertificate: trust), apiKey: apiKey.isEmpty ? nil : apiKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .textFieldStyle(.roundedBorder)
        .tint(.fmGreen)
    }

    private func test() {
        testing = true
        testResult = ""
        let key = apiKey.isEmpty ? (Keychain.read(account: Keychain.unifiKeyAccount) ?? "") : apiKey
        let cfg = UniFiConfig(url: url, trustCertificate: trust)
        Task { @MainActor in
            testResult = await state.testUniFi(config: cfg, apiKey: key)
            testing = false
        }
    }
}
