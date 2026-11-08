import Foundation

struct Health: Codable, Equatable {
    var engine: String
    var ytdlp: String
    var ffmpeg: String?
    var jsRuntime: String?
    var pid: Int?
}

struct Prefs: Codable, Equatable {
    var folder: String = NSString(string: "~/Downloads/Dwn").expandingTildeInPath
    var kind: String = "video"
    var videoFormat: String = "h264"
    var audioFormat: String = "mp3"
    var maxHeight: Int = 0
    var concurrency: Int = 3
    var embedMetadata: Bool = true
    var embedThumbnail: Bool = true
    var embedSubs: Bool = false
    var browserCookies: String = ""
}

struct LoginCheck: Codable, Equatable {
    var ok: Bool
    var signedIn: Bool?
    var cookies: Int?
    var reason: String?
    var message: String?
}

struct Browser: Identifiable, Hashable {
    var id: String      // yt-dlp name
    var name: String
    var bundleID: String

    static let all: [Browser] = [
        Browser(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome"),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser"),
        Browser(id: "edge", name: "Edge", bundleID: "com.microsoft.edgemac"),
        Browser(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox"),
    ]

    static func named(_ id: String) -> Browser? { all.first { $0.id == id } }
}

struct Chapter: Codable, Hashable {
    var title: String?
    var start: Double?
    var end: Double?
}

struct Heat: Codable, Hashable {
    var start: Double?
    var end: Double?
    var value: Double?
}

struct LinkInfo: Codable, Equatable {
    var url: String?
    var title: String?
    var uploader: String?
    var duration: Double?
    var thumbnail: String?
    var site: String?
    var liveStatus: String?
    var isPlaylist: Bool?
    var count: Int?
    var chapters: [Chapter]?
    var heatmap: [Heat]?

    var isLive: Bool { ["is_live", "is_upcoming", "post_live"].contains(liveStatus ?? "") }
}

struct Preview: Codable {
    var stream: String
    var headers: [String: String]?
    var duration: Double?
    var title: String?
    var heatmap: [Heat]?
    var chapters: [Chapter]?
    var height: Int?
    var vcodec: String?
    var videoBps: Double?
    var audioBps: Double?
}

struct FramesResult: Codable { var frames: [String: String] }

/// A section the user picked with Done, used by the next download of that link.
struct SectionChoice: Equatable {
    var url: String
    var start: Double
    var end: Double
}

struct Job: Codable, Identifiable, Equatable {
    var id: String
    var url: String
    var title: String
    var thumbnail: String?
    var kind: String
    var format: String
    var state: String
    var stage: String
    var progress: Double
    var speed: Double?
    var eta: Double?
    var error: String?
    var errorCode: String?
    var file: String?
    var created: Double
    var batch: String?
    var start: Double?
    var end: Double?
    var mode: String?

    var isActive: Bool { ["queued", "running", "converting"].contains(state) }
}

struct HistoryItem: Codable, Identifiable, Equatable {
    var id: String
    var url: String
    var title: String?
    var thumbnail: String?
    var kind: String?
    var format: String?
    var file: String?
    var finished: Double?
    var exists: Bool?
    var start: Double?
    var end: Double?
}

struct BulkItem: Codable, Identifiable, Equatable {
    var url: String?
    var title: String?
    var duration: Double?
    var thumbnail: String?
    var playlist: String?
    var error: String?
    var downloaded: Bool?

    var id: String { (url ?? "") + (title ?? "") }
}

struct BulkExpand: Codable {
    var items: [BulkItem]
    var skipped: [String]
}

struct UpdateResult: Codable {
    var updated: Bool
    var version: String
    var restart: Bool?
}

struct FileResult: Codable { var file: String }

enum Formats {
    static let video: [(id: String, name: String, note: String)] = [
        ("h264", "H.264 .mp4", "Plays everywhere. 1440p and 4K take longer to convert."),
        ("hevc", "HEVC .mp4", "About a third smaller. Takes longer, as every video is converted."),
        ("prores", "ProRes .mov", "For Premiere and After Effects. Much bigger files."),
        ("original", "Original", "Exactly what the site sends, often VP9 or AV1. Fastest."),
    ]
    static let audio: [(id: String, name: String, note: String)] = [
        ("mp3", "MP3", "Up to 320 kbps. Plays on every phone, car stereo and app."),
        ("aac", "AAC .m4a", "The site's own sound, untouched. Great on Apple devices."),
        ("wav", "WAV", "Uncompressed, for editing. About ten times bigger."),
    ]
    static let heights: [(Int, String)] = [(0, "Best available"), (2160, "4K"), (1440, "1440p"),
                                            (1080, "1080p"), (720, "720p"), (480, "480p")]

    static func name(_ id: String) -> String {
        (video + audio).first { $0.id == id }?.name ?? id
    }
}

enum Time {
    /// Accepts "90", "1:30", "1:02:03", "2m", "62m", "3723s", "1h2m3s".
    static func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Double($0) }
            if parts.contains(where: { $0 == nil }) { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        if let v = Double(t) { return v }
        var total = 0.0, num = ""
        for ch in t {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num) else { return nil }
            switch ch {
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            default: return nil
            }
            num = ""
        }
        if let v = Double(num) { total += v }
        return total
    }

    static func format(_ secs: Double?, tenths: Bool = false) -> String {
        guard let secs, secs.isFinite else { return "–" }
        let s = max(0, secs)
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if tenths { out += String(format: ".%d", Int((s - floor(s)) * 10)) }
        return out
    }
}

func formatBytes(_ b: Double?) -> String {
    guard let b else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

func looksLikeLink(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !t.contains(" "), !t.contains("\n") else { return false }
    if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) != nil }
    return t.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+/\S*$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

func normalizeLink(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.hasPrefix("http") ? t : "https://" + t
}
