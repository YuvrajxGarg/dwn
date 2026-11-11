import AppKit
import Foundation
import UserNotifications

// MARK: - Engine types

struct CloudService: Codable, Hashable {
    var type: String
    var name: String
}

struct CloudViewInfo: Codable, Hashable {
    var id: String
    var title: String
}

struct CloudAccount: Codable, Identifiable, Hashable {
    var name: String
    var type: String
    var service: String
    var email: String?
    var label: String
    var views: [CloudViewInfo]
    /// Signed in through Dwn's own Google app rather than rclone's shared one.
    var ownClient: Bool?
    var id: String { name }
}

struct CloudAuth: Codable, Equatable {
    var id: String?
    var type: String?
    var state: String?      // starting | waiting | done | failed | cancelled
    var url: String?
    var error: String?
    var account: CloudAccount?
}

struct CloudClient: Codable, Equatable {
    var id: String?
    var mine: Bool
}

struct CloudStatus: Codable {
    var available: Bool
    var services: [CloudService]
    var accounts: [CloudAccount]
    var connecting: CloudAuth?
    var version: String?
    var error: String?
}

struct CloudEntry: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var isDir: Bool
    var size: Double?
    var modified: String?
    var mime: String?
    var owner: String?
    var id: String { path }
    var date: Date? { CloudDates.parse(modified) }
}

struct CloudListing: Codable {
    var fs: String
    var path: String
    var items: [CloudEntry]
}

struct CloudTransfer: Codable, Identifiable, Equatable {
    var id: String
    var direction: String      // down | up
    var account: String
    var name: String
    var isDir: Bool
    var state: String          // queued | running | done | failed | cancelled
    var bytes: Double
    var total: Double?
    var speed: Double?
    var eta: Double?
    var files: Int
    var filesTotal: Int?
    var error: String?
    var created: Double
    var finished: Double?
    var local: String?
    var current: [String]?

    var isActive: Bool { state == "queued" || state == "running" }
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, bytes / total)
    }
}

/// Where the cloud pane is: one view (My Drive, Shared with me, a shared link)
/// of one account, a folder path inside it, and for "Shared with me" the
/// person whose files are shown.
struct CloudLocation: Hashable, Codable {
    var account: String
    var view: String = "files"
    var link: String? = nil
    var path: String = ""
    var owner: String? = nil

    var root: CloudLocation { CloudLocation(account: account, view: view, link: link) }
}

/// A Google Drive folder link the user opened, kept in the sidebar.
struct SavedLink: Codable, Hashable, Identifiable {
    var account: String
    var link: String
    var title: String
    var id: String { account + "|" + link }
}

/// A file or folder on this computer, for the local pane.
struct LocalEntry: Identifiable, Hashable {
    var url: URL
    var isDir: Bool
    var size: Double?
    var date: Date?
    var name: String { url.lastPathComponent }
    var id: String { url.path }
}

enum CloudDates {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// rclone times can carry up to nine fractional digits; drop them.
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: trimmed)
    }
}

/// Payload for dragging cloud items onto the local pane.
struct CloudDrag: Codable {
    var location: CloudLocation
    var items: [CloudEntry]
    static let prefix = "dwn-cloud:"

    var string: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + (String(data: data, encoding: .utf8) ?? "")
    }

    static func parse(_ s: String) -> CloudDrag? {
        guard s.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(CloudDrag.self, from: Data(s.dropFirst(prefix.count).utf8))
    }
}

/// Payload for dragging several local files onto the cloud pane at once.
enum LocalDrag {
    static let prefix = "dwn-local:"
    static func string(_ paths: [String]) -> String {
        prefix + ((try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? "[]")
    }
    static func parse(_ s: String) -> [String]? {
        guard s.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(s.dropFirst(prefix.count).utf8))
    }
}

// MARK: - Model

@MainActor
final class CloudModel: ObservableObject {
    unowned let app: AppModel

    @Published var status: CloudStatus?
    @Published var location: CloudLocation? {
        didSet { if location != oldValue { selection = [] } }
    }
    @Published var entries: [CloudEntry] = []
    /// Narrows both panes by name (the field above them).
    @Published var filter = ""
    @Published var loading = false
    @Published var listError: String?
    @Published var selection = Set<String>()
    @Published var transfers: [CloudTransfer] = []
    @Published var auth: CloudAuth?
    @Published var showConnect = false
    @Published var showLink = false
    @Published var links: [SavedLink] = CloudModel.loadLinks() {
        didSet { if let d = try? JSONEncoder().encode(links) { UserDefaults.standard.set(d, forKey: "cloudLinks") } }
    }
    @Published var usage: [String: (used: Double, total: Double)] = [:]
    @Published var clients: [String: CloudClient] = [:]

    @Published var localFolder: URL {
        didSet {
            UserDefaults.standard.set(localFolder.path, forKey: "cloudLocalFolder")
            localSelection = []
            refreshLocal()
        }
    }
    @Published var localEntries: [LocalEntry] = []
    @Published var localSelection = Set<String>()

    private var listTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var knownFinished = Set<String>()
    private var cache: [CloudLocation: [CloudEntry]] = [:]

    init(app: AppModel) {
        self.app = app
        let saved = UserDefaults.standard.string(forKey: "cloudLocalFolder")
        localFolder = URL(fileURLWithPath: saved ?? app.prefs.folder)
    }

    var accounts: [CloudAccount] { status?.accounts ?? [] }
    func account(_ name: String?) -> CloudAccount? { accounts.first { $0.name == name } }
    var activeTransfers: Int { transfers.filter(\.isActive).count }

    // MARK: lifecycle

    /// Called when the Cloud tab appears.
    func activate() {
        if !FileManager.default.fileExists(atPath: localFolder.path) {
            try? FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        }
        refreshLocal()
        Task { await refreshStatus() }
        startPolling()
    }

    func refreshStatus() async {
        guard let api = app.api else { return }
        do {
            let s: CloudStatus = try await api.call("cloud/status")
            status = s
            if location == nil || account(location?.account) == nil {
                // Test hook: start in another view, e.g. DWN_TEST_CLOUD_VIEW=shared.
                let view = ProcessInfo.processInfo.environment["DWN_TEST_CLOUD_VIEW"] ?? "files"
                location = s.accounts.first.map { CloudLocation(account: $0.name, view: view) }
                if location != nil { reload() } else { entries = [] }
            }
            for a in s.accounts where usage[a.name] == nil { loadUsage(a.name) }
            if let c: [String: CloudClient] = try? await api.call("cloud/clients") { clients = c }
        } catch {
            status = CloudStatus(available: false, services: [], accounts: [], error: error.localizedDescription)
        }
    }

    private func loadUsage(_ name: String) {
        Task {
            struct About: Codable { var total: Double?; var used: Double? }
            guard let api = app.api, let a: About = try? await api.call("cloud/about", ["account": name]),
                  let used = a.used else { return }
            usage[name] = (used, a.total ?? 0)
        }
    }

    // MARK: browsing

    func open(_ loc: CloudLocation) {
        location = loc
        reload()
    }

    func reload(force: Bool = false) {
        guard let loc = location, let api = app.api else { return }
        listTask?.cancel()
        listError = nil
        let key = CloudLocation(account: loc.account, view: loc.view, link: loc.link, path: loc.path)
        if let hit = cache[key], !force { entries = hit } else { entries = []; loading = true }
        listTask = Task {
            var body: [String: Any] = ["account": loc.account, "view": loc.view, "path": loc.path]
            if let l = loc.link { body["link"] = l }
            do {
                let r: CloudListing = try await api.call("cloud/list", body)
                guard !Task.isCancelled, location?.account == loc.account, location?.path == loc.path,
                      location?.view == loc.view, location?.link == loc.link else { return }
                cache[key] = r.items
                entries = r.items
            } catch {
                guard !Task.isCancelled else { return }
                listError = error.localizedDescription
                entries = []
            }
            loading = false
        }
    }

    /// At the top of "Shared with me", Drive tells us who owns each item;
    /// the pane groups them by person, like a list of people sharing with you.
    var people: [(owner: String, count: Int)]? {
        guard let loc = location, loc.view == "shared", loc.path.isEmpty, loc.owner == nil,
              account(loc.account)?.type == "drive" else { return nil }
        let owners = entries.compactMap(\.owner)
        guard !owners.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for o in owners { counts[o, default: 0] += 1 }
        let unknown = entries.filter { $0.owner == nil }.count
        var list = counts.map { ($0.key, $0.value) }.sorted { $0.0.lowercased() < $1.0.lowercased() }
        if unknown > 0 { list.append(("Others", unknown)) }
        return list
    }

    var visibleEntries: [CloudEntry] {
        guard let loc = location, loc.path.isEmpty, let owner = loc.owner else { return entries }
        return entries.filter { ($0.owner ?? "Others") == owner }
    }

    func enter(_ e: CloudEntry) {
        guard e.isDir, var loc = location else { return }
        loc.path = e.path
        open(loc)
    }

    func showPerson(_ owner: String) {
        guard var loc = location else { return }
        loc.owner = owner
        location = loc   // same listing, filtered: no reload needed
    }

    func goUp() {
        guard var loc = location else { return }
        if loc.path.isEmpty {
            if loc.owner != nil { loc.owner = nil; location = loc }
            return
        }
        loc.path = (loc.path as NSString).deletingLastPathComponent
        open(loc)
    }

    /// Breadcrumbs: (title, location) from the root down.
    var crumbs: [(String, CloudLocation)] {
        guard let loc = location, let acct = account(loc.account) else { return [] }
        var out: [(String, CloudLocation)] = []
        let rootTitle = loc.view == "link" ? (links.first { $0.link == loc.link }?.title ?? "Shared link")
            : (acct.views.first { $0.id == loc.view }?.title ?? "Files")
        out.append((rootTitle, loc.root))
        if let o = loc.owner {
            var l = loc.root; l.owner = o
            out.append((o, l))
        }
        var p = ""
        for part in loc.path.split(separator: "/") {
            p = p.isEmpty ? String(part) : p + "/" + part
            var l = loc.root; l.owner = loc.owner; l.path = p
            out.append((String(part), l))
        }
        return out
    }

    func navigate(_ l: CloudLocation) {
        if l.path == location?.path && l.view == location?.view && l.link == location?.link {
            location = l   // only the person filter changed
        } else { open(l) }
    }

    func newFolder(_ name: String) {
        guard let loc = location, let api = app.api, !name.isEmpty else { return }
        Task {
            let path = loc.path.isEmpty ? name : loc.path + "/" + name
            var body: [String: Any] = ["account": loc.account, "view": loc.view, "path": path]
            if let l = loc.link { body["link"] = l }
            do {
                let _: AnyDecodable = try await api.call("cloud/mkdir", body)
                reload(force: true)
            } catch { app.toast(error.localizedDescription, error: true) }
        }
    }

    func deleteSelected() {
        guard let loc = location, let api = app.api else { return }
        let items = entries.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        Task {
            var body: [String: Any] = ["account": loc.account, "view": loc.view,
                                       "items": items.map { ["path": $0.path, "is_dir": $0.isDir] }]
            if let l = loc.link { body["link"] = l }
            do {
                let _: AnyDecodable = try await api.call("cloud/delete", body)
                app.toast(items.count == 1 ? "Moved “\(items[0].name)” to the trash." : "Moved \(items.count) items to the trash.")
                reload(force: true)
            } catch { app.toast(error.localizedDescription, error: true) }
        }
    }

    // MARK: accounts

    func connect(_ service: String, replacing: CloudAccount? = nil) {
        guard let api = app.api else { return }
        authTask?.cancel()
        auth = CloudAuth(type: service, state: "starting")
        authTask = Task {
            do {
                var body: [String: Any] = ["service": service]
                if let r = replacing { body["replace"] = r.name }
                let a: CloudAuth = try await api.call("cloud/connect", body)
                auth = a
                if let u = a.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let s: CloudAuth = try? await api.call("cloud/connect/status") else { continue }
                    if auth?.url == nil, let u = s.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
                    auth = s
                    if s.state == "done" {
                        await refreshStatus()
                        if let acct = s.account {
                            cache = cache.filter { $0.key.account != acct.name }
                            open(CloudLocation(account: acct.name))
                            app.toast("Connected \(acct.label).")
                        }
                        auth = nil
                        showConnect = false
                        NSApp.activate(ignoringOtherApps: true)
                        return
                    }
                    if s.state == "failed" || s.state == "cancelled" { return }
                }
            } catch {
                auth = CloudAuth(type: service, state: "failed", error: error.localizedDescription)
            }
        }
    }

    /// Sign in again, e.g. to move an account onto Dwn's own Google app.
    func reconnect(_ acct: CloudAccount) {
        showConnect = true
        connect(acct.type, replacing: acct)
    }

    func saveClient(_ service: String, id: String, secret: String) async -> String? {
        guard let api = app.api else { return "The download engine isn't running." }
        do {
            clients = try await api.call("cloud/clients", ["service": service, "id": id, "secret": secret])
            return nil
        } catch { return error.localizedDescription }
    }

    func cancelConnect() {
        authTask?.cancel()
        auth = nil
        Task { let _: AnyDecodable? = try? await app.api?.call("cloud/connect/cancel", [:]) }
    }

    func disconnect(_ acct: CloudAccount) {
        Task {
            do {
                let _: AnyDecodable? = try await app.api?.call("cloud/disconnect", ["account": acct.name])
                links.removeAll { $0.account == acct.name }
                if location?.account == acct.name { location = nil }
                await refreshStatus()
            } catch { app.toast(error.localizedDescription, error: true) }
        }
    }

    func addLink(_ link: String, account: String) {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let n = links.filter { $0.account == account }.count + 1
        let saved = links.first { $0.link == t && $0.account == account }
            ?? SavedLink(account: account, link: t, title: "Shared link \(n)")
        if !links.contains(saved) { links.append(saved) }
        open(CloudLocation(account: account, view: "link", link: t))
    }

    func renameLink(_ l: SavedLink, to title: String) {
        guard let i = links.firstIndex(of: l), !title.isEmpty else { return }
        links[i].title = title
    }

    func removeLink(_ l: SavedLink) {
        links.removeAll { $0 == l }
        if location?.view == "link" && location?.link == l.link { location = location.map { CloudLocation(account: $0.account) }; reload() }
    }

    private static func loadLinks() -> [SavedLink] {
        guard let d = UserDefaults.standard.data(forKey: "cloudLinks") else { return [] }
        return (try? JSONDecoder().decode([SavedLink].self, from: d)) ?? []
    }

    // MARK: transfers

    /// Copy cloud items into a folder on this computer (the local pane's folder by default).
    func download(_ items: [CloudEntry], from loc: CloudLocation, to folder: URL? = nil) {
        guard let api = app.api else { return }
        var list = items
        // Nothing picked inside a folder: take the whole folder you're looking at.
        if list.isEmpty {
            guard !loc.path.isEmpty || loc.view == "link" else { return }
            let name = loc.path.isEmpty ? (links.first { $0.link == loc.link }?.title ?? "Shared folder")
                : (loc.path as NSString).lastPathComponent
            list = [CloudEntry(name: name, path: loc.path, isDir: true)]
        }
        let dest = folder ?? localFolder
        Task {
            var body: [String: Any] = ["account": loc.account, "view": loc.view, "dest": dest.path,
                                       "items": list.map { ["path": $0.path, "name": $0.name, "is_dir": $0.isDir] }]
            if let l = loc.link { body["link"] = l }
            do {
                let t: [CloudTransfer] = try await api.call("cloud/download", body)
                transfers.append(contentsOf: t.filter { n in !transfers.contains { $0.id == n.id } })
                startPolling()
            } catch { app.toast(error.localizedDescription, error: true) }
        }
    }

    /// Copy files and folders from this computer into the cloud folder you're looking at.
    func upload(_ paths: [String], to loc: CloudLocation? = nil) {
        guard let loc = loc ?? location, let api = app.api, !paths.isEmpty else { return }
        if loc.view != "files" && loc.view != "link" {
            app.toast("You can't add files here. Open My Drive or one of your folders first.", error: true)
            return
        }
        Task {
            var body: [String: Any] = ["account": loc.account, "view": loc.view, "path": loc.path, "files": paths]
            if let l = loc.link { body["link"] = l }
            do {
                let t: [CloudTransfer] = try await api.call("cloud/upload", body)
                transfers.append(contentsOf: t)
                startPolling()
            } catch { app.toast(error.localizedDescription, error: true) }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refreshTransfers()
                if !transfers.contains(where: \.isActive) { break }
                try? await Task.sleep(for: .milliseconds(700))
            }
            pollTask = nil
        }
    }

    func refreshTransfers() async {
        guard let api = app.api, let list: [CloudTransfer] = try? await api.call("cloud/transfers") else { return }
        if list != transfers { transfers = list }
        for t in list where !t.isActive && !knownFinished.contains(t.id) {
            knownFinished.insert(t.id)
            guard t.state == "done" else { continue }
            if t.direction == "down" { refreshLocal() } else if t.account == location?.account { reload(force: true) }
            notifyFinished(t)
        }
    }

    private func notifyFinished(_ t: CloudTransfer) {
        guard !NSApp.isActive else { return }
        let c = UNMutableNotificationContent()
        c.title = t.direction == "down" ? "Downloaded from the cloud" : "Uploaded"
        c.body = t.name
        c.userInfo = ["file": t.direction == "down" ? (t.local ?? "") : ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id, content: c, trigger: nil))
    }

    func transferAction(_ t: CloudTransfer, _ action: String) {
        Task {
            let _: AnyDecodable? = try? await app.api?.call("cloud/transfers/\(t.id)/\(action)", [:])
            if action == "retry" { knownFinished.remove(t.id) }
            await refreshTransfers()
            startPolling()
        }
    }

    func clearFinished() {
        Task {
            let _: AnyDecodable? = try? await app.api?.call("cloud/transfers/clear", [:])
            await refreshTransfers()
        }
    }

    // MARK: local pane

    func refreshLocal() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: localFolder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        localEntries = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LocalEntry(url: u, isDir: v?.isDirectory ?? false, size: v?.fileSize.map(Double.init),
                              date: v?.contentModificationDate)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = localFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localFolder = url
    }
}
