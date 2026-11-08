import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Checks GitHub Releases for a newer Dwn, notifies once per version, and
/// installs it in place: download → verify SHA-256 → unzip → swap → relaunch.
///
/// Release assets it expects: `Dwn-mac.zip` and `Dwn-mac.zip.sha256`.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
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
    /// Shown when the user clicks the update pill or notification.
    @Published var showSheet = false

    let repo: String = Bundle.main.object(forInfoDictionaryKey: "DwnUpdateRepo") as? String ?? "YuvrajxGarg/dwn"
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var hasUpdate: Bool {
        if case .available = phase { return true }
        if case .downloading = phase { return true }
        return false
    }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if autoCheck { await check(manual: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.autoCheck == true { await self?.check(manual: false) } }
        }
    }

    // MARK: check

    func check(manual: Bool) async {
        if case .downloading = phase { return }
        phase = .checking
        do {
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
            if Self.isNewer(rel.version, than: current) {
                phase = .available
                notifyOnce(rel)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = manual ? .failed(error.localizedDescription) : .idle
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
        c.body = "Click to see what's new and update."
        c.userInfo = ["update": rel.version]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(rel.version)", content: c, trigger: nil))
    }

    // MARK: install

    func install() async {
        guard let rel = latest else { return }
        guard let zipURL = rel.zip else {
            NSWorkspace.shared.open(rel.page)
            return
        }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), target.pathExtension == "app" else {
            phase = .failed("This copy can't update itself where it is. The download page opens instead.")
            NSWorkspace.shared.open(rel.page)
            return
        }
        do {
            phase = .downloading(0)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("DwnUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
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

            phase = .installing
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

            // Swap the app once Dwn has quit, then reopen it.
            let script = work.appendingPathComponent("swap.sh")
            try """
            #!/bin/sh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(target.path).old"
            mv "\(target.path)" "\(target.path).old" && mv "\(newApp.path)" "\(target.path)" && rm -rf "\(target.path).old"
            open "\(target.path)"
            rm -rf "\(work.path)"
            """.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to dest: URL) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(message: "The update server didn't have the update. Try again later.")
        }
        let total = max(resp.expectedContentLength, 1)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let h = try FileHandle(forWritingTo: dest)
        defer { try? h.close() }
        var buf = Data()
        buf.reserveCapacity(1 << 20)
        var got: Int64 = 0
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                try h.write(contentsOf: buf)
                got += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                phase = .downloading(min(0.99, Double(got) / Double(total)))
            }
        }
        try h.write(contentsOf: buf)
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
