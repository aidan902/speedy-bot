import AppKit
import Vision

/// Finds out the remote machine's own address from inside a ScreenConnect session.
///
/// A short PowerShell line is typed into the session; it prints one marker line
/// (`SPEEDYBOT 172.16.37.46/23 gw=172.16.36.1 host=FLC-JACKSON pub=…`) and also copies it, so the answer comes
/// back two ways: through ScreenConnect's clipboard sharing, or by reading the session window off the screen.
enum SessionProbe {
    static let marker = "SPEEDYBOT"

    /// Windows PowerShell 5 (Windows 8 / Server 2012 and later). Single quotes only, so it survives being
    /// handed over as `powershell -c "…"`, and no character outside plain ASCII.
    static let script =
        "$c=(Get-NetIPConfiguration|?{$_.IPv4DefaultGateway})[0];$a=$c.IPv4Address[0];"
        + "$l='\(marker) '+$a.IPAddress+'/'+$a.PrefixLength+' gw='+$c.IPv4DefaultGateway.NextHop"
        + "+' host='+$env:COMPUTERNAME+' pub='+$(try{irm http://api.ipify.org -TimeoutSec 4}catch{''});"
        + "Set-Clipboard $l;$l"

    struct Reading: Equatable, Sendable {
        let ip: IPv4
        let prefix: Int
        let gateway: String?
        let host: String?
        let publicIP: String?
    }

    /// The marker line out of any text (clipboard or screen reading). The address and prefix must follow the
    /// marker; the rest is optional. Screen reading can split one printed line into several, so the text
    /// is searched as a whole, within a short distance of the marker.
    static func parse(_ text: String) -> Reading? {
        let flat = text.replacingOccurrences(of: "SPEEDY BOT", with: marker)
            .components(separatedBy: .newlines).joined(separator: " ")
        var from = flat.startIndex
        while let r = flat.range(of: marker, range: from..<flat.endIndex) {
            from = r.upperBound
            let rest = String(flat[r.upperBound...].prefix(220))
            guard let m = rest.firstMatch(of: /(\d{1,3}(?:\.\d{1,3}){3})\s*\/\s*(\d{1,2})/),
                  let ip = IPv4(String(m.1)), let prefix = Int(m.2), (8...30).contains(prefix) else { continue }
            func field(_ name: String) -> String? {
                guard let f = rest.firstMatch(of: try! Regex("\(name)=(\\S+)")) else { return nil }
                let v = String(f[1].substring ?? "")
                return v.isEmpty || v == "none" ? nil : v
            }
            let gw = field("gw").flatMap { IPv4($0)?.description }
            let pub = field("pub").flatMap { IPv4($0)?.description }
            return Reading(ip: ip, prefix: prefix, gateway: gw, host: field("host"), publicIP: pub)
        }
        return nil
    }

    /// Four digits that read well off a screen (no 0/O or 1/l).
    static func token() -> String { String((0..<4).map { _ in "23456789".randomElement()! }) }

    /// A marker such as "SB7342 OPEN" is on screen (spacing as the recognizer saw it).
    static func marker(_ text: String, token: String, word: String) -> Bool {
        guard let re = try? Regex("(?i)SB\\s*\(token)\\s*\(word)") else { return false }
        return text.firstMatch(of: re) != nil
    }

    /// Reads the text shown in a window off the screen (Screen Recording permission). Nil when the capture
    /// or the recognition fails.
    static func screenText(windowID: CGWindowID, keepCaptureAt: String? = nil) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let path = keepCaptureAt ?? NSTemporaryDirectory() + "speedybot-probe-\(getpid()).png"
                defer { if keepCaptureAt == nil { try? FileManager.default.removeItem(atPath: path) } }
                let started = Date()
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(windowID), path]
                do { try task.run() } catch { cont.resume(returning: nil); return }
                task.waitUntilExit()
                let captured = Date()
                guard task.terminationStatus == 0, let image = NSImage(contentsOfFile: path),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { cont.resume(returning: nil); return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false   // addresses are not words
                do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { cont.resume(returning: nil); return }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                SpeedyShared.log.notice("screen text: capture \(Int(captured.timeIntervalSince(started) * 1000)) ms (\(cg.width)x\(cg.height)), recognition \(Int(Date().timeIntervalSince(captured) * 1000)) ms, \(lines.count) lines")
                cont.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// Watches the session for an answer: on the clipboard (ScreenConnect shares the remote clipboard) and
    /// on the screen. Made BEFORE anything is typed, so a clipboard change during the typing counts too.
    @MainActor
    final class Watch {
        private let windowID: CGWindowID
        private var baseline = NSPasteboard.general.changeCount
        private var lastRead = -1
        private var cancelled = false

        init(windowID: CGWindowID) { self.windowID = windowID }

        func cancel() { cancelled = true }

        /// This app changed the clipboard itself: that change is not an answer.
        func ignoreClipboardNow() { baseline = NSPasteboard.general.changeCount; lastRead = -1 }

        /// The first value `match` makes out of the clipboard text or the screen text, and where it came
        /// from ("clipboard" or "screen"); nil after `timeout` seconds.
        func wait<T>(timeout: TimeInterval, clipboard: Bool, every: TimeInterval = 0.8,
                     _ match: (String) -> T?) async -> (value: T, via: String)? {
            let deadline = Date().addingTimeInterval(timeout)
            var nextScreen = Date().addingTimeInterval(0.4)
            while Date() < deadline, !cancelled {
                if clipboard {
                    let pb = NSPasteboard.general
                    let count = pb.changeCount
                    if count != baseline, count != lastRead, ClipboardSwap.canReadSilently {
                        lastRead = count
                        if let s = pb.string(forType: .string), let v = match(s) { return (v, "clipboard") }
                    }
                }
                if Date() >= nextScreen {
                    nextScreen = Date().addingTimeInterval(every)
                    if let text = await screenText(windowID: windowID), let v = match(text) { return (v, "screen") }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }
    }
}
