import AppKit
import Security

/// Keeps Speedy Bot up to date from its GitHub releases.
///
/// A release carries three files: the app as a zip, a disk image for people, and `SpeedyBot-update.json`
/// (version, build number, the zip's name). The updater reads the newest release, and when its build number is
/// higher than the running one it downloads the zip, unpacks it next to the installed app, and checks the
/// unpacked app before it is allowed anywhere near the installed one:
///
///   - its code signature is intact, all the way down;
///   - it is this app (same bundle id) signed with a Developer ID certificate of THIS team;
///   - it is notarized, if the running copy is (a notarized install never steps down to a build that is not);
///   - its build number really is higher (an old, genuinely signed build cannot be replayed as an "update").
///
/// Only then is the installed copy swapped, by a small script that waits for this process to quit, and the app
/// reopened. The Accessibility permission carries over because the signature identity is the same.
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repo = "aidan902/speedy-bot"
    nonisolated static let teamID = "SRPFLCC723"
    nonisolated static let infoAsset = "SpeedyBot-update.json"

    /// One line for the window: what the updater last did or found.
    @Published private(set) var status = ""
    /// A newer version that was found but not installed (automatic updates are off, or the app cannot replace itself).
    @Published private(set) var available: String?

    private unowned let state: AppState
    private var timer: Timer?
    private var checking = false
    private var staged: (bundle: URL, version: String)?
    private var idleTimer: Timer?

    init(state: AppState) { self.state = state }

    nonisolated static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    nonisolated static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    func start() {
        announceIfJustUpdated()
        // Shortly after launch, then four times a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.check(userAsked: false) }
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userAsked: false) }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func announceIfJustUpdated() {
        let d = SpeedyShared.defaults
        if d.string(forKey: SpeedyShared.updatedToKey) == Self.currentVersion + " (\(Self.currentBuild))" {
            Toast.show("Speedy Bot updated to \(Self.currentVersion)", seconds: 3)
        }
        d.removeObject(forKey: SpeedyShared.updatedToKey)
    }

    // MARK: checking

    func check(userAsked: Bool) {
        guard !checking else { return }
        guard userAsked || state.autoUpdate else { return }
        checking = true
        if userAsked { status = "Checking for updates…" }
        let includeBetas = state.betaUpdates
        Task { @MainActor in
            defer { self.checking = false }
            do {
                guard let found = try await Self.newestRelease(includeBetas: includeBetas) else {
                    self.status = "No published version found"
                    return
                }
                guard found.build > Self.currentBuild else {
                    self.available = nil
                    self.status = "Up to date (\(Self.currentVersion))"
                    return
                }
                guard userAsked || self.state.autoUpdate else { return }
                guard Self.canReplaceSelf else {
                    self.available = found.version
                    self.status = "Version \(found.version) is available, but this account cannot replace the app. Reinstall it from the download link."
                    return
                }
                self.status = "Downloading version \(found.version)…"
                let bundle = try await Self.downloadAndVerify(found)
                self.staged = (bundle, found.version)
                self.available = nil
                self.status = "Version \(found.version) is ready. Installing…"
                SpeedyShared.log.notice("update \(found.version, privacy: .public) (build \(found.build)) downloaded and verified")
                self.installWhenIdle()
            } catch {
                SpeedyShared.log.error("update check failed: \(String(describing: error), privacy: .public)")
                self.status = userAsked ? "Could not check for updates: \(Self.describe(error))" : self.status
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    struct Release: Sendable {
        let version: String
        let build: Int
        let zipURL: URL
    }

    struct UpdateError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    nonisolated private static func fetch(_ url: URL, accept: String? = nil) async throws -> Data {
        guard url.scheme == "https" else { throw UpdateError(message: "refusing a link that is not https") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.setValue("SpeedyBot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError(message: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// The newest published release that carries update information (newest first, as GitHub lists them).
    nonisolated private static func newestRelease(includeBetas: Bool) async throws -> Release? {
        let list = try await fetch(URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!, accept: "application/vnd.github+json")
        guard let releases = try JSONSerialization.jsonObject(with: list) as? [[String: Any]] else { return nil }
        for release in releases {
            if release["draft"] as? Bool == true { continue }
            if release["prerelease"] as? Bool == true, !includeBetas { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            func link(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }.flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            }
            guard let infoURL = link(infoAsset) else { continue }
            guard let info = try JSONSerialization.jsonObject(with: try await fetch(infoURL)) as? [String: Any],
                  let version = info["version"] as? String, let build = info["build"] as? Int,
                  let zipName = info["zip"] as? String, let zipURL = link(zipName) else { continue }
            return Release(version: version, build: build, zipURL: zipURL)
        }
        return nil
    }

    // MARK: download + verify

    private static var installedBundle: URL { Bundle.main.bundleURL.standardizedFileURL }

    /// The app can only replace itself where this account may write, and never from a disk image.
    private static var canReplaceSelf: Bool {
        let fm = FileManager.default
        let bundle = installedBundle
        return fm.isWritableFile(atPath: bundle.path) && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && !bundle.path.hasPrefix("/Volumes/") && !bundle.path.contains("/AppTranslocation/")
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { done in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { done.resume(returning: -1) }
        }
    }

    /// Downloads the zip, unpacks it beside the installed app (same volume, so the swap is a rename), and
    /// returns the unpacked bundle only if it passes every check.
    private static func downloadAndVerify(_ release: Release) async throws -> URL {
        let fm = FileManager.default
        let parent = installedBundle.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".SpeedyBot-update-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        do {
            let zip = stage.appendingPathComponent("update.zip")
            try await fetch(release.zipURL).write(to: zip)
            guard await run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]) == 0 else {
                throw UpdateError(message: "the download could not be unpacked")
            }
            try? fm.removeItem(at: zip)
            let bundle = stage.appendingPathComponent(installedBundle.lastPathComponent)
            guard fm.fileExists(atPath: bundle.path) else { throw UpdateError(message: "the download does not contain the app") }
            try verify(bundle, expectedBuild: release.build)
            return bundle
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess ? req : nil
    }

    /// Is the running copy notarized? Then an update must be too.
    static var runningCopyIsNotarized: Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, let notarized = requirement("notarized") else { return false }
        return SecCodeCheckValidity(me, [], notarized) == errSecSuccess
    }

    private static func verify(_ bundle: URL, expectedBuild: Int) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError(message: "the downloaded app has no readable signature")
        }
        let id = Bundle.main.bundleIdentifier ?? SpeedyShared.appBundleID
        var text = "identifier \"\(id)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        if runningCopyIsNotarized { text += " and notarized" }
        guard let req = requirement(text) else { throw UpdateError(message: "could not build the signature check") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else {
            throw UpdateError(message: "the downloaded app is not a genuine Speedy Bot build")
        }
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let build = Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
        guard build == expectedBuild, build > currentBuild else {
            throw UpdateError(message: "the downloaded app is not newer than this one")
        }
    }

    // MARK: install

    /// Swapping the app means quitting it, so wait until nothing is in progress.
    private func installWhenIdle() {
        idleTimer?.invalidate()
        if !state.typing && !state.armed { install(); return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.state.typing, !self.state.armed else { return }
                self.idleTimer?.invalidate()
                self.install()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func install() {
        guard let staged else { return }
        let dest = Self.installedBundle
        // Waits for this process to go, swaps the bundles (putting the old one back if the swap fails), reopens.
        let script = """
        pid="$1"; new="$2"; dest="$3"; stage="$4"
        (
          i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
          old="$stage/previous.app"
          if mv "$dest" "$old"; then
            if mv "$new" "$dest"; then rm -rf "$stage"; else mv "$old" "$dest"; fi
          fi
          /usr/bin/open "$dest"
        ) >/dev/null 2>&1 &
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), staged.bundle.path, dest.path,
                       staged.bundle.deletingLastPathComponent().path]
        do {
            try p.run()
        } catch {
            status = "Could not start the update"
            return
        }
        let d = SpeedyShared.defaults
        let info = NSDictionary(contentsOf: staged.bundle.appendingPathComponent("Contents/Info.plist"))
        d.set("\(staged.version) (\(info?["CFBundleVersion"] as? String ?? "0"))", forKey: SpeedyShared.updatedToKey)
        d.set(Date().timeIntervalSince1970, forKey: SpeedyShared.quietLaunchKey)   // come back without throwing the window up
        SpeedyShared.log.notice("installing update \(staged.version, privacy: .public) and relaunching")
        NSApp.terminate(nil)
    }
}
