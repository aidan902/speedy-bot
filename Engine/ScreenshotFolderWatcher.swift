// Notices screenshots the system SAVES AS FILES (the tech's normal screenshot behaviour), by watching the
// folder they are saved to. A screenshot file is recognised by the tag macOS puts on it
// (com.apple.metadata:kMDItemIsScreenCapture), not by its name, which depends on language and settings.
//
// "New" means a file that was not there before AND was created in the last few minutes. Renaming an old
// screenshot, moving one in from elsewhere, or a sync service delivering one is not a new screenshot.
import Foundation

@MainActor
public final class ScreenshotFolderWatcher {
    public private(set) var folder: URL?
    /// False once the watched folder has been renamed, deleted or unmounted: the owner should start again.
    public private(set) var isAlive = false
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var seenFiles = Set<UInt64>()     // inode numbers: a renamed file is still the same file
    private let onScreenshot: (URL) -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf", "bmp"]
    private static let screenshotTag = "com.apple.metadata:kMDItemIsScreenCapture"
    /// The corner preview can hold a file back while the tech marks it up; older than this is not "just taken".
    private static let freshness: TimeInterval = 180

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
        seenFiles = Set(names.compactMap { Self.inode(folder.appendingPathComponent($0)) })
        self.folder = folder
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            let gone = src.map { !$0.data.intersection([.rename, .delete, .revoke]).isEmpty } ?? false
            MainActor.assumeIsolated { self?.changed(folderGone: gone) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        isAlive = true
        return true
    }

    public func stop() {
        source?.cancel(); source = nil
        folder = nil
        isAlive = false
        known.removeAll()
        seenFiles.removeAll()
    }

    /// The folder changed. The file's screenshot tag can land a moment after the file itself, so look again shortly.
    private func changed(folderGone: Bool) {
        if folderGone { isAlive = false; return }   // the folder itself was renamed, deleted or unmounted
        scan()
        for delay in [0.35, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    private func scan() {
        guard isAlive, let folder else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { isAlive = false; return }
        let current = Set(names)
        known.formIntersection(current)
        // Shortest name first: a capture of two displays saves "… AM.png" and "… AM (2).png"; the first is the main display.
        for name in current.subtracting(known).sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            if name.hasPrefix(".") { continue }        // still being written under a temporary name
            let url = folder.appendingPathComponent(name)
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { known.insert(name); continue }
            let id = Self.inode(url)
            if let id, seenFiles.contains(id) { known.insert(name); continue }   // an old file under a new name
            if Self.isCloudPlaceholder(url) {                                    // synced in from another Mac, not downloaded
                known.insert(name)
                if let id { seenFiles.insert(id) }
                continue
            }
            let age = Self.age(of: url)
            if Self.isScreenshot(url) {
                known.insert(name)
                if let id { seenFiles.insert(id) }
                if age <= Self.freshness { onScreenshot(url) }   // otherwise: an old screenshot that was moved or synced in
            } else if age > 4 {
                known.insert(name)                     // some other picture that was put in the folder
                if let id { seenFiles.insert(id) }
            }
            // otherwise: too new to judge; one of the follow-up scans decides
        }
    }

    private static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, screenshotTag, nil, 0, 0, 0) >= 0
    }

    private static func isCloudPlaceholder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static func inode(_ url: URL) -> UInt64? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    private static func age(of url: URL) -> TimeInterval {
        guard let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date else { return .infinity }
        return Date().timeIntervalSince(created)
    }
}
