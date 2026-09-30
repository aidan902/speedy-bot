// Notices screenshots the system SAVES AS FILES (the tech's normal screenshot behaviour), by watching the
// folder they are saved to. A screenshot file is recognised by the tag macOS puts on it
// (com.apple.metadata:kMDItemIsScreenCapture), not by its name, which depends on language and settings.
import Foundation

@MainActor
public final class ScreenshotFolderWatcher {
    public private(set) var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private let onScreenshot: (URL) -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf", "bmp"]
    private static let screenshotTag = "com.apple.metadata:kMDItemIsScreenCapture"

    public init(onScreenshot: @escaping (URL) -> Void) { self.onScreenshot = onScreenshot }

    /// False when the folder cannot be opened or listed (it does not exist, or macOS has not been allowed
    /// to let this app into it).
    @discardableResult
    public func start(folder: URL) -> Bool {
        stop()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        known = Set(names)               // everything already there is not news
        self.folder = folder
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    public func stop() {
        source?.cancel(); source = nil
        folder = nil
        known.removeAll()
    }

    /// The folder changed. The file's screenshot tag can land a moment after the file itself, so look again shortly.
    private func changed() {
        scan()
        for delay in [0.35, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    private func scan() {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let current = Set(names)
        known.formIntersection(current)
        // Shortest name first: a capture of two displays saves "… AM.png" and "… AM (2).png"; the first is the main display.
        for name in current.subtracting(known).sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            if name.hasPrefix(".") { continue }        // still being written under a temporary name
            let url = folder.appendingPathComponent(name)
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { known.insert(name); continue }
            if Self.isScreenshot(url) {
                known.insert(name)
                onScreenshot(url)
            } else if Self.age(of: url) > 4 {
                known.insert(name)                     // some other picture that was put in the folder
            }
            // otherwise: too new to judge; one of the follow-up scans decides
        }
    }

    private static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, screenshotTag, nil, 0, 0, 0) >= 0
    }

    private static func age(of url: URL) -> TimeInterval {
        guard let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date else { return .infinity }
        return Date().timeIntervalSince(created)
    }
}
