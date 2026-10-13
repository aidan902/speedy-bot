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
    /// handed over as `powershell -Command "…"` by the Run dialog, and no character outside plain ASCII.
    static let script =
        "$c=Get-NetIPConfiguration|?{$_.IPv4DefaultGateway}|select -First 1;"
        + "$a=Get-NetIPAddress -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4|select -First 1;"
        + "$l='\(marker) '+$a.IPAddress+'/'+$a.PrefixLength+' gw='+$c.IPv4DefaultGateway.NextHop"
        + "+' host='+$env:COMPUTERNAME+' pub='+$(try{irm https://api.ipify.org -TimeoutSec 4}catch{'none'});"
        + "Set-Clipboard $l;$l"

    struct Reading: Equatable, Sendable {
        let ip: IPv4
        let prefix: Int
        let gateway: String?
        let host: String?
        let publicIP: String?
    }

    /// The marker line out of any text (clipboard or screen reading). The address and prefix must be there;
    /// the rest is optional.
    static func parse(_ text: String) -> Reading? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "SPEEDY BOT", with: marker)
            guard let r = line.range(of: marker) else { continue }
            let rest = String(line[r.upperBound...])
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

    /// Waits for the marker line: on the clipboard (ScreenConnect shares the remote clipboard) or on screen.
    /// Made BEFORE the script is typed, so a clipboard change during the typing is noticed too.
    @MainActor
    final class Watch {
        private let windowID: CGWindowID
        private let baseline = NSPasteboard.general.changeCount
        private var lastRead = -1
        private var cancelled = false

        init(windowID: CGWindowID) { self.windowID = windowID }

        func cancel() { cancelled = true }

        /// The reading and where it came from ("clipboard" or "screen"), or nil after `timeout` seconds.
        func result(timeout: TimeInterval) async -> (reading: Reading, via: String)? {
            let deadline = Date().addingTimeInterval(timeout)
            var nextScreen = Date().addingTimeInterval(1.5)
            while Date() < deadline, !cancelled {
                let pb = NSPasteboard.general
                let count = pb.changeCount
                if count != baseline, count != lastRead, ClipboardSwap.canReadSilently {
                    lastRead = count
                    if let s = pb.string(forType: .string), let r = parse(s) { return (r, "clipboard") }
                }
                if Date() >= nextScreen {
                    nextScreen = Date().addingTimeInterval(1.2)
                    if let text = await screenText(windowID: windowID), let r = parse(text) { return (r, "screen") }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return nil
        }
    }
}
