import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Keeps Dwn up to date from GitHub Releases.
///
/// - Every install first asks GitHub for the newest release, so Dwn always
///   jumps straight to the latest version and never installs one in between.
/// - With automatic updates on, the newest version downloads quietly in the
///   background (verified with SHA-256 and unpacked) and is installed the next
///   time Dwn quits, or right away with "Restart to update". If an even newer
///   release appears before then, it replaces the one waiting.
///
/// Release assets: `Dwn-mac.zip` and `Dwn-mac.zip.sha256`.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
        case ready          // newest version downloaded and waiting to be installed
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var zip: URL?
        var sha: URL?
        var published: Date?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date
    @Published var autoCheck = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }
    /// Download new versions in the background and install them when Dwn quits.
    @Published var autoInstall = UserDefaults.standard.object(forKey: "updateAutoInstall") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoInstall, forKey: "updateAutoInstall")
            if autoInstall, case .available = phase { Task { await stageNewest() } }
        }
    }
    /// Shown when the user clicks the update pill or notification.
    @Published var showSheet = false

    let repo: String = Bundle.main.object(forInfoDictionaryKey: "DwnUpdateRepo") as? String ?? "YuvrajxGarg/dwn"
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .ready, .installing: return true
        default: return false
        }
    }
    var isReady: Bool { if case .ready = phase { return true } else { return false } }

    private var timer: Timer?
    private var staging = false

    /// Where a downloaded update waits: ~/Library/Application Support/Dwn/Update/Dwn.app
    private var stageDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dwn/Update")
    }
    private var stagedApp: URL { stageDir.appendingPathComponent("Dwn.app") }
    private var stagedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateStagedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateStagedVersion") }
    }

    func start() {
        guard timer == nil else { return }
        // A staged update that's no newer than what's running is leftover; drop it.
        if let v = stagedVersion, !Self.isNewer(v, than: current) { discardStaged() }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if autoCheck { await check(manual: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.autoCheck == true { await self?.check(manual: false) } }
        }
    }

    // MARK: check

    /// The newest published release, straight from GitHub (never cached).
    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Dwn/\(current)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw APIError(message: "No releases have been published yet.") }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Couldn't reach the update server. Check your connection.")
        }
        let tag = (obj["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            (assets.first { ($0["name"] as? String) == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        let rel = Release(
            version: tag,
            notes: obj["body"] as? String ?? "",
            page: URL(string: obj["html_url"] as? String ?? "https://github.com/\(repo)/releases")!,
            zip: asset("Dwn-mac.zip"),
            sha: asset("Dwn-mac.zip.sha256"),
            published: (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        latest = rel
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
        return rel
    }

    func check(manual: Bool) async {
        if case .downloading = phase { return }
        if case .installing = phase { return }
        let wasReady = isReady
        if !wasReady { phase = .checking }
        do {
            let rel = try await fetchLatest()
            guard Self.isNewer(rel.version, than: current) else { phase = .upToDate; return }
            if stagedVersion == rel.version, FileManager.default.fileExists(atPath: stagedApp.path) {
                phase = .ready
            } else {
                phase = .available
                notifyOnce(rel)
                if autoInstall { await stageNewest() }
            }
        } catch {
            if wasReady { phase = .ready } else { phase = manual ? .failed(error.localizedDescription) : .idle }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func notifyOnce(_ rel: Release) {
        let key = "updateNotified"
        guard UserDefaults.standard.string(forKey: key) != rel.version else { return }
        UserDefaults.standard.set(rel.version, forKey: key)
        let c = UNMutableNotificationContent()
        c.title = "Dwn \(rel.version) is available"
        c.body = autoInstall ? "It's downloading in the background and installs when you quit Dwn."
                             : "Click to see what's new and update."
        c.userInfo = ["update": rel.version]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(rel.version)", content: c, trigger: nil))
    }

    // MARK: staging

    /// Download, verify and unpack the newest release into the staging folder.
    /// Asks GitHub for the newest version first, so an in-between version is never staged.
    @discardableResult
    func stageNewest() async -> Bool {
        guard !staging else { return false }
        staging = true
        defer { staging = false }
        do {
            let rel = try await fetchLatest()
            guard Self.isNewer(rel.version, than: current) else { phase = .upToDate; return false }
            if stagedVersion == rel.version, FileManager.default.fileExists(atPath: stagedApp.path) {
                phase = .ready
                return true
            }
            guard let zipURL = rel.zip else { phase = .available; return false }

            phase = .downloading(0)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("DwnUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("Dwn-mac.zip")
            try await download(zipURL, to: zip)

            if let shaURL = rel.sha {
                let (shaData, _) = try await URLSession.shared.data(from: shaURL)
                let expected = String(decoding: shaData, as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)?.lowercased() ?? ""
                let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { throw APIError(message: "The update didn't download intact. Try again.") }
            }

            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("Dwn.app")
            guard let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw APIError(message: "The update couldn't be unpacked. Try again.")
            }
            guard (plist["CFBundleShortVersionString"] as? String) == rel.version else {
                throw APIError(message: "The update isn't the version it said it was.")
            }
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            discardStaged()
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: newApp, to: stagedApp)
            stagedVersion = rel.version
            phase = .ready
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func discardStaged() {
        try? FileManager.default.removeItem(at: stagedApp)
        stagedVersion = nil
    }

    // MARK: install

    /// "Update and restart": make sure the newest version is staged, then swap and relaunch.
    func install() async {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              target.pathExtension == "app" else {
            phase = .failed("This copy can't update itself where it is. The download page opens instead.")
            NSWorkspace.shared.open(latest?.page ?? URL(string: "https://github.com/\(repo)/releases/latest")!)
            return
        }
        // Re-check right now: if a newer release came out since the last check, get that one.
        guard await stageNewest(), isReady else { return }
        phase = .installing
        do {
            try launchSwap(relaunch: true)
            showSheet = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quitDwn(force: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { exit(0) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called as Dwn quits for real: install a waiting update without reopening.
    func installOnQuit() {
        guard autoInstall, isReady, let v = stagedVersion, Self.isNewer(v, than: current),
              FileManager.default.fileExists(atPath: stagedApp.path) else { return }
        try? launchSwap(relaunch: false)
    }

    /// A small script that waits for Dwn to exit, swaps in the staged app and optionally reopens it.
    private func launchSwap(relaunch: Bool) throws {
        let target = Bundle.main.bundleURL
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("dwn-swap-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        [ -d "\(stagedApp.path)" ] || exit 1
        rm -rf "\(target.path).old"
        mv "\(target.path)" "\(target.path).old" && mv "\(stagedApp.path)" "\(target.path)" && rm -rf "\(target.path).old"
        defaults delete \(Bundle.main.bundleIdentifier ?? "com.yuvrajgarg.dwn") updateStagedVersion 2>/dev/null
        \(relaunch ? "open \"\(target.path)\"" : "")
        rm -f "$0"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
    }

    /// Downloads with a native URLSession download task: full network speed,
    /// written straight to disk, progress reported a few times a second.
    private func download(_ url: URL, to dest: URL) async throws {
        let loader = FileDownload(url: url) { [weak self] p in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(min(0.99, p))
            }
        }
        let tmp = try await loader.run()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        phase = .downloading(1)
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw APIError(message: "The update couldn't be unpacked. Try again.") }
    }
}

/// Bridges a URLSessionDownloadTask (delegate based) to async/await with progress.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReport = Date.distantPast
    private var session: URLSession?

    init(url: URL, onProgress: @escaping (Double) -> Void) {
        self.url = url
        self.onProgress = onProgress
    }

    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            continuation = c
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            s.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.15 else { return }
        lastReport = Date()
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it somewhere we own first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("DwnDownload-\(UUID().uuidString)")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw APIError(message: "The update server didn't have the update. Try again later.") }
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(APIError(message: "The download stopped. Check your connection and try again. (\(error.localizedDescription))"))) }
    }

    private func finish(_ r: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        c.resume(with: r)
    }
}
