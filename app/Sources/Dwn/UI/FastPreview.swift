import AppKit
import SwiftUI

/// In-memory + on-disk image cache so thumbnails appear instantly the second time.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, NSImage>()
    private let session: URLSession

    init() {
        memory.countLimit = 400
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20,
                                directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                    .appendingPathComponent("Dwn/images"))
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: String) -> NSImage? { memory.object(forKey: url as NSString) }

    func load(_ url: String) async -> NSImage? {
        if let hit = cached(url) { return hit }
        guard let u = URL(string: url) else { return nil }
        if u.isFileURL, let img = NSImage(contentsOf: u) {
            memory.setObject(img, forKey: url as NSString)
            return img
        }
        guard let (data, _) = try? await session.data(from: u), let img = NSImage(data: data) else { return nil }
        memory.setObject(img, forKey: url as NSString)
        return img
    }
}

/// Instant link previews that don't wait for full extraction.
enum FastPreview {
    /// The video ID from youtube.com/watch?v=, youtu.be/, /shorts/, /embed/, /live/ links.
    static func youtubeID(_ link: String) -> String? {
        guard let u = URLComponents(string: normalizeLink(link)), let host = u.host?.lowercased() else { return nil }
        let path = u.path.split(separator: "/").map(String.init)
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = path.first
        } else if host.contains("youtube.com") {
            if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { id = v }
            else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) { id = path[1] }
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// 16:9 thumbnail (no letterbox bars), available without any lookup.
    static func youtubeThumbnail(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/mqdefault.jpg" }

    /// A first preview for YouTube links: thumbnail immediately, title from oEmbed (~0.2 s).
    static func quickInfo(_ link: String) -> LinkInfo? {
        guard let id = youtubeID(link) else { return nil }
        return LinkInfo(url: normalizeLink(link), title: nil, uploader: nil, duration: nil,
                        thumbnail: youtubeThumbnail(id), site: "Youtube")
    }

    static func oembed(_ link: String) async -> (title: String, author: String?)? {
        guard youtubeID(link) != nil,
              var c = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        c.queryItems = [URLQueryItem(name: "url", value: normalizeLink(link)), URLQueryItem(name: "format", value: "json")]
        guard let u = c.url, let (data, _) = try? await URLSession.shared.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String else { return nil }
        return (title, obj["author_name"] as? String)
    }

    /// Merge the full engine lookup over the quick one, keeping the already-loaded thumbnail.
    static func merge(quick: LinkInfo?, full: LinkInfo) -> LinkInfo {
        var out = full
        if let t = quick?.thumbnail, full.isPlaylist != true { out.thumbnail = t }
        return out
    }
}

/// Thumbnail view backed by ImageCache (shows instantly if already loaded).
struct Thumb: View {
    var url: String?
    @Local private var image: NSImage?
    @Local private var shownURL: String?

    var body: some View {
        let img = (shownURL == url ? image : nil) ?? url.flatMap { ImageCache.shared.cached($0) }
        ZStack {
            Color.white.opacity(0.06)
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if url != nil {
                Shimmer()
            } else {
                Image(systemName: "play.rectangle").foregroundStyle(Theme.text3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            guard let url else { return }
            let loaded = await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded; shownURL = url }
        }
    }
}

// MARK: - Storyboards

struct SBSheet: Codable { var path: String; var start: Double; var duration: Double }
struct SBLevel: Codable {
    var width: Int?
    var height: Int?
    var rows: Int?
    var columns: Int?
    var interval: Double?
    var sheets: [SBSheet]
}
struct StoryboardResult: Codable { var levels: [SBLevel] }

/// Crops individual frames out of YouTube's storyboard sprite sheets.
final class Storyboard {
    let levels: [SBLevel]
    private var images: [String: CGImage] = [:]

    init(_ r: StoryboardResult) { levels = r.levels }

    var isEmpty: Bool { levels.isEmpty }

    func frame(at t: Double, large: Bool) -> NSImage? {
        guard let level = large ? levels.last : levels.first,
              let rows = level.rows, let cols = level.columns, let w = level.width, let h = level.height,
              let sheet = level.sheets.last(where: { $0.start <= t }) ?? level.sheets.first else { return nil }
        let per = rows * cols
        let interval = level.interval ?? (sheet.duration / Double(per))
        let idx = max(0, min(per - 1, Int((t - sheet.start) / max(interval, 0.01))))
        guard let img = cgImage(sheet.path) else { return nil }
        let rect = CGRect(x: (idx % cols) * w, y: (idx / cols) * h, width: w, height: h)
        guard rect.maxX <= CGFloat(img.width), rect.maxY <= CGFloat(img.height),
              let tile = img.cropping(to: rect) else { return nil }
        return NSImage(cgImage: tile, size: NSSize(width: w, height: h))
    }

    private func cgImage(_ path: String) -> CGImage? {
        if let c = images[path] { return c }
        guard let ns = NSImage(contentsOfFile: path),
              let c = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        images[path] = c
        return c
    }
}
