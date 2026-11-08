import AVKit
import SwiftUI

/// Pick the part of a video to download: live preview, start/end cards with
/// frame thumbnails, and a zoomable filmstrip timeline with trim handles.
struct SectionEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var info: LinkInfo

    enum Edge { case start, end, none }

    @Local private var preview: Preview?
    @Local private var loadError: String?
    @Local private var player = AVPlayer()
    @Local private var start: Double = 0
    @Local private var end: Double = 0
    @Local private var position: Double = 0
    @Local private var playing = false
    @Local private var edge: Edge = .start
    @Local private var zoom: CGFloat = 1
    @Local private var strip: [Double: NSImage] = [:]
    @Local private var edgeFrames: [Edge: NSImage] = [:]
    @Local private var lengthText = ""
    @Local private var timeObserver: Any?
    @Local private var edgeTask: Task<Void, Never>?
    @Local private var storyboard: Storyboard?
    @Local private var storyboardTried = false
    @FocusState private var lengthFocused: Bool

    private var duration: Double { preview?.duration ?? info.duration ?? 0 }
    private var trimmed: Bool { start > 0.05 || end < duration - 0.05 }
    private var length: Double { max(0, end - start) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .center, spacing: 20) {
                playerView
                VStack(spacing: 10) {
                    edgeCard(.start)
                    edgeCard(.end)
                    lengthRow
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)

            timeline
                .padding(.horizontal, 24)
                .padding(.top, 22)
            tools
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 18)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            footer
        }
        .frame(width: 940)
        .background(Theme.sidebar)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { key in handleKey(key) }
        .task { await load() }
        .onDisappear {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }
        .onChange(of: start) { _, _ in edgesChanged() }
        .onChange(of: end) { _, _ in edgesChanged() }
    }

    // MARK: header & footer

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a section").font(.ui(19, .bold)).foregroundStyle(Theme.text)
                Text([info.title ?? preview?.title, duration > 0 ? Time.format(duration) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(12.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(estimateText).font(.ui(12).monospacedDigit()).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            Button {
                model.sectionChoice = trimmed ? SectionChoice(url: info.url ?? "", start: start, end: end) : nil
                dismiss()
            } label: { Label("Done", systemImage: "checkmark") }
                .buttonStyle(QuietButtonStyle(height: 38))
                .help("Keep this section and go back")
            Button { download() } label: {
                Label(trimmed ? "Download section" : "Download whole video", systemImage: "arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle(height: 38))
            .frame(width: 220)
            .keyboardShortcut(.defaultAction)
            .disabled(duration <= 0 && preview == nil)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: player

    private var playerView: some View {
        ZStack {
            Color.black
            if preview != nil {
                PlayerSurface(player: player)
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.ui(18)).foregroundStyle(Theme.text3)
                    Text("Preview unavailable").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(loadError).font(.ui(11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                        .lineLimit(3).frame(maxWidth: 300)
                    Button("Try again") { Task { await load() } }.buttonStyle(QuietButtonStyle(height: 30))
                }
            } else {
                if info.thumbnail != nil {
                    Thumb(url: info.thumbnail).frame(width: 520, height: 292).opacity(0.85)
                }
                ProgressView().controlSize(.small)
                    .padding(10).background(Circle().fill(.black.opacity(0.5)))
            }
        }
        .frame(width: 520, height: 292)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topLeading) {
            if preview != nil {
                HStack(spacing: 6) {
                    if edge != .none && !playing {
                        Text(edge == .start ? "Start" : "End").foregroundStyle(Theme.text2)
                    }
                    Text(Time.format(position, tenths: true)).foregroundStyle(.white)
                }
                .font(.ui(12, .semibold).monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(12)
            }
        }
        .overlay {
            if preview != nil {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.ui(20, .bold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .opacity(playing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: playing)
                .help("Play this section with sound (Space)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if preview != nil { togglePlay() } }
    }

    // MARK: edge cards

    private func edgeCard(_ e: Edge) -> some View {
        let t = e == .start ? start : end
        let on = edge == e
        return HStack(spacing: 14) {
            ZStack {
                Color.white.opacity(0.05)
                if let img = edgeFrames[e] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Shimmer()
                }
            }
            .frame(width: 104, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Label(e == .start ? "Start" : "End", systemImage: e == .start ? "flag.fill" : "flag.checkered")
                    .font(.ui(12, .semibold)).foregroundStyle(on ? Theme.text : Theme.text2)
                Text(Time.format(t, tenths: zoom > 2))
                    .font(.ui(22, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { nudge(e, by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 30)).help("Back a second (Option: a tenth)")
                Button { nudge(e, by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(IconButtonStyle(size: 30)).help("Forward a second (Option: a tenth)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(on ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(on ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { edge = e; seek(t) }
        .animation(.easeOut(duration: 0.12), value: on)
    }

    private var lengthRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3).frame(width: M.iconColumn)
            Text("Length").font(.ui(13, .medium)).foregroundStyle(Theme.text2)
            Spacer()
            TextField("", text: $lengthText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.ui(15, .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 90)
                .focused($lengthFocused)
                .onSubmit {
                    if let v = Time.parse(lengthText), v > 0 { end = min(duration, start + v) }
                    syncLength()
                }
                .help("Type a length, like 20, 1:30 or 2m")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: timeline

    private var timeline: some View {
        GeometryReader { geo in
            let base = geo.size.width
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: zoom > 1) {
                    TimelineTrack(duration: max(duration, 0.1), width: base * zoom,
                                  start: $start, end: $end, position: position, frames: strip,
                                  chapters: preview?.chapters ?? info.chapters ?? [],
                                  onSeek: { t in edge = .none; seek(t, exact: false) },
                                  onEdge: { e, t in edge = e; seek(t, exact: false) },
                                  onEnded: { seek(position) })
                        .id("track")
                }
                .scrollDisabled(zoom <= 1)
                .onChange(of: zoom) { _, _ in proxy.scrollTo("track", anchor: UnitPoint(x: start / max(duration, 1), y: 0.5)) }
            }
            .task(id: "\(Int(base * zoom))-\(duration)") { await loadStrip(width: base * zoom) }
        }
        .frame(height: 96)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach([5.0, 10, 15, 30, 60, 120], id: \.self) { s in
                    Button(s < 60 ? "\(Int(s)) seconds" : "\(Int(s / 60)) minute\(s >= 120 ? "s" : "")") {
                        setLength(s)
                    }
                }
            } label: {
                toolLabel("timer", trimmed ? Time.format(length) : "Length")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Make the section that long, from the start")

            let chapters = (preview?.chapters ?? info.chapters ?? []).filter { $0.start != nil }
            if !chapters.isEmpty {
                Menu {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, c in
                        Button("\(Time.format(c.start))  \(c.title ?? "Chapter")") {
                            start = c.start ?? 0
                            end = min(duration, c.end ?? duration)
                            edge = .start
                            seek(start)
                        }
                    }
                } label: {
                    toolLabel("list.bullet", "Chapters", chevron: true)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }

            if let peak = mostReplayed {
                Button {
                    start = peak.0; end = peak.1; edge = .start; seek(peak.0)
                } label: { toolLabel("flame", "Most replayed") }
                    .buttonStyle(.plain)
                    .help("Jump to the part people replay most")
            }

            if trimmed {
                Button { start = 0; end = duration; edge = .start; seek(0) } label: {
                    toolLabel("arrow.uturn.backward", "Reset")
                }
                .buttonStyle(.plain)
            }

            Spacer()
            HStack(spacing: 2) {
                Button { withAnimation(.easeOut(duration: 0.2)) { zoom = max(1, zoom / 2) } } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 30)).disabled(zoom <= 1).help("Zoom out")
                Button { withAnimation(.easeOut(duration: 0.2)) { zoom = min(maxZoom, zoom * 2) } } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 30)).disabled(zoom >= maxZoom).help("Zoom in")
            }
            .padding(3)
            .controlFill()
        }
    }

    private func toolLabel(_ icon: String, _ title: String, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.ui(11.5, .semibold)).foregroundStyle(Theme.text3)
            Text(title).font(.ui(12.5, .medium).monospacedDigit()).foregroundStyle(Theme.text)
            if chevron { Image(systemName: "chevron.down").font(.ui(9, .bold)).foregroundStyle(Theme.text3) }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .controlFill()
        .contentShape(Rectangle())
    }

    private var maxZoom: CGFloat { max(1, min(32, CGFloat(duration / 8))) }

    // MARK: estimate

    private var estimateText: String {
        guard let p = preview else { return duration > 0 ? "" : "Getting video details…" }
        let len = length > 0 ? length : duration
        var parts: [String] = []
        var bytes = 0.0
        var convertSecs = 0.0
        let srcRate = (p.videoBps ?? 0) + (p.audioBps ?? 0)
        if model.tab == "audio" {
            parts.append(Formats.name(model.prefs.audioFormat))
            switch model.prefs.audioFormat {
            case "mp3": bytes = 40_000 * len
            case "wav": bytes = 176_400 * len
            default: bytes = (p.audioBps ?? 16_000) * len
            }
        } else {
            let codec = model.prefs.videoFormat
            parts.append(["h264": "H.264", "hevc": "HEVC", "prores": "ProRes", "original": "Original"][codec] ?? codec)
            let h = Double(p.height ?? 720)
            if let height = p.height { parts.append("\(height)p") }
            bytes = srcRate * len
            let isAVC = (p.vcodec ?? "").hasPrefix("avc")
            if codec == "hevc" { bytes *= 0.7; convertSecs = len * h / 1080 * 0.35 }
            if codec == "prores" { bytes = 27_500_000 * pow(h / 1080, 2) * len; convertSecs = len * h / 1080 * 0.3 }
            if codec == "h264" && !isAVC { convertSecs = len * h / 1080 * 0.35 }
        }
        guard bytes > 0 else { return parts.joined(separator: " · ") }
        parts.append("≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        let secs = srcRate * len / 6_000_000 + convertSecs + 2
        parts.append("ready in about " + (secs < 60 ? "\(Int(secs.rounded())) s" : "\(Int((secs / 60).rounded())) min"))
        return parts.joined(separator: " · ")
    }

    private var mostReplayed: (Double, Double)? {
        let heat = (preview?.heatmap ?? info.heatmap ?? []).filter { $0.value != nil }
        guard let peak = heat.max(by: { ($0.value ?? 0) < ($1.value ?? 0) }), let s = peak.start else { return nil }
        let mid = (s + (peak.end ?? s)) / 2
        return (max(0, mid - 10), min(duration, mid + 20))
    }

    // MARK: actions

    private func load() async {
        loadError = nil
        guard let url = info.url, let api = model.api else { return }
        if let c = model.sectionChoice, c.url == url { start = c.start; end = c.end }
        if end <= 0, let d = info.duration { end = d }
        Task { await loadStoryboard(url: url, api: api) }
        do {
            let p: Preview = try await api.call("preview", ["url": url])
            guard let streamURL = URL(string: p.stream) else { throw APIError(message: "The preview has no playable video.") }
            preview = p
            let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": p.headers ?? [:]])
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if end <= 0 { end = p.duration ?? info.duration ?? 0 }
            syncLength()
            seek(start)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                          queue: .main) { t in
                MainActor.assumeIsolated {
                    guard playing else { return }
                    position = t.seconds
                    if position >= end - 0.03 { player.pause(); playing = false; position = end }
                }
            }
            edgesChanged()
        } catch {
            loadError = error.localizedDescription
            if end <= 0, let d = info.duration { end = d; syncLength() }
        }
    }

    /// YouTube storyboard sprites: low-res frames for the whole video in one or two requests.
    private func loadStoryboard(url: String, api: API) async {
        let r: StoryboardResult? = try? await api.call("storyboard", ["url": url])
        if let r, !r.levels.isEmpty { storyboard = Storyboard(r) }
        storyboardTried = true
        edgesChanged()
    }

    private func loadStrip(width: CGFloat) async {
        guard let url = info.url, let api = model.api else { return }
        // 1. Storyboard tiles as soon as they're here (instant on YouTube).
        while !storyboardTried && preview == nil && loadError == nil {
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
        }
        while duration <= 0 && loadError == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        let count = max(6, min(80, Int(width / 92)))
        let times = (0..<count).map { ((Double($0) + 0.5) * duration / Double(count) * 10).rounded() / 10 }
        if let sb = storyboard, strip.count != count {
            var quick: [Double: NSImage] = [:]
            for t in times { if let img = sb.frame(at: t, large: false) { quick[t] = img } }
            if quick.count == count { strip = quick }
        }
        // 2. Sharp frames from the video itself replace them.
        while preview == nil && loadError == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        if loadError != nil { return }
        guard let r: FramesResult = try? await api.call("frames", ["url": url, "times": times, "width": 192]) else { return }
        var next: [Double: NSImage] = [:]
        for (k, path) in r.frames {
            if let t = Double(k), let img = NSImage(contentsOfFile: path) { next[t] = img }
        }
        if !Task.isCancelled { strip = next }
    }

    private func edgesChanged() {
        syncLength()
        // Instant, approximate frames from the storyboard; exact ones follow.
        if let sb = storyboard {
            if let a = sb.frame(at: start, large: true) { edgeFrames[.start] = a }
            if let b = sb.frame(at: max(start, end - 0.1), large: true) { edgeFrames[.end] = b }
        }
        edgeTask?.cancel()
        edgeTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let url = info.url, let api = model.api, preview != nil else { return }
            let s = (start * 10).rounded() / 10, e = (max(start, end - 0.1) * 10).rounded() / 10
            guard let r: FramesResult = try? await api.call("frames", ["url": url, "times": [s, e], "width": 320]) else { return }
            var next = edgeFrames
            if let p = r.frames[String(format: "%.1f", s)], let img = NSImage(contentsOfFile: p) { next[.start] = img }
            if let p = r.frames[String(format: "%.1f", e)], let img = NSImage(contentsOfFile: p) { next[.end] = img }
            if !Task.isCancelled { edgeFrames = next }
        }
    }

    private func syncLength() {
        if !lengthFocused { lengthText = Time.format(length) }
    }

    private func seek(_ t: Double, exact: Bool = true) {
        position = t
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
    }

    private func togglePlay() {
        if playing {
            player.pause()
            playing = false
        } else {
            if position < start || position >= end - 0.1 { seek(start) }
            player.play()
            playing = true
        }
    }

    private func nudge(_ e: Edge, by secs: Double) {
        let step = NSEvent.modifierFlags.contains(.option) ? secs / 10 : secs
        edge = e
        if e == .start {
            start = min(max(0, start + step), end - 0.1)
            seek(start)
        } else {
            end = max(min(duration, end + step), start + 0.1)
            seek(end)
        }
    }

    private func setLength(_ s: Double) {
        end = min(duration, start + s)
        if end - start < s { start = max(0, end - s) }
        edge = .end
        seek(end)
    }

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        if lengthFocused { return .ignored }
        let fine = key.modifiers.contains(.option)
        switch key.key {
        case .space:
            togglePlay(); return .handled
        case .leftArrow, .rightArrow:
            let dir: Double = key.key == .leftArrow ? -1 : 1
            let step = dir * (fine ? 0.1 : 1)
            switch edge {
            case .none: seek(min(max(0, position + step), duration))
            case .start: start = min(max(0, start + step), end - 0.1); seek(start)
            case .end: end = max(min(duration, end + step), start + 0.1); seek(end)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func download() {
        let url = info.url ?? ""
        let s = start, e = end, cut = trimmed
        let kind = model.tab == "audio" ? "audio" : "video"
        model.sectionChoice = nil
        Task {
            if await model.download(url, info: info, kind: kind, start: cut ? s : nil, end: cut ? e : nil) {
                model.toast(cut ? "Downloading section \(Time.format(s))–\(Time.format(e))" : "Download started.")
                if normalizeLink(model.composerText) == url { model.composerText = "" }
            }
        }
        dismiss()
    }
}

/// The filmstrip with time ruler, dimmed outside the selection, white trim frame and playhead.
struct TimelineTrack: View {
    var duration: Double
    var width: CGFloat
    @Binding var start: Double
    @Binding var end: Double
    var position: Double
    var frames: [Double: NSImage]
    var chapters: [Chapter]
    var onSeek: (Double) -> Void
    var onEdge: (SectionEditorView.Edge, Double) -> Void
    var onEnded: () -> Void
    @Local private var moveOrigin: [Double]?

    private let stripHeight: CGFloat = 62
    private let handleW: CGFloat = 12

    var body: some View {
        let x = { (t: Double) in CGFloat(t / duration) * width }
        let t = { (px: CGFloat) in min(max(Double(px / width) * duration, 0), duration) }
        VStack(alignment: .leading, spacing: 8) {
            ruler(x)
            ZStack(alignment: .topLeading) {
                filmstrip
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { onSeek(t($0.location.x)) }
                        .onEnded { _ in onEnded() })

                // Dim outside the selection.
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, x(start)), height: stripHeight)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, width - x(end)), height: stripHeight)
                    .offset(x: x(end)).allowsHitTesting(false)

                ForEach(chapters.compactMap(\.start).filter { $0 > 0 }, id: \.self) { c in
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 10).offset(x: x(c), y: stripHeight - 10)
                        .allowsHitTesting(false)
                }

                // Selection frame: drag inside to move the whole section.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: max(handleW * 2, x(end) - x(start)), height: stripHeight + 4)
                    .contentShape(Rectangle())
                    .offset(x: x(start), y: -2)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if moveOrigin == nil { moveOrigin = [start, end] }
                            guard let o = moveOrigin else { return }
                            let len = o[1] - o[0]
                            let ns = min(max(0, o[0] + Double(g.translation.width / width) * duration), duration - len)
                            start = ns; end = ns + len
                            onEdge(.start, ns)
                        }
                        .onEnded { _ in moveOrigin = nil; onEnded() })

                handle.offset(x: x(start), y: -2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { g in start = min(t(g.location.x), end - 0.1); onEdge(.start, start) }
                        .onEnded { _ in onEnded() })
                handle.offset(x: x(end) - handleW, y: -2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { g in end = max(t(g.location.x), start + 0.1); onEdge(.end, end) }
                        .onEnded { _ in onEnded() })

                // Playhead
                VStack(spacing: 0) {
                    Circle().fill(Theme.accent).frame(width: 9, height: 9)
                    Rectangle().fill(Theme.accent).frame(width: 2, height: stripHeight + 4)
                }
                .offset(x: x(position) - 4.5, y: -8)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: stripHeight, alignment: .topLeading)
            .coordinateSpace(name: "strip")
        }
        .frame(width: width, alignment: .leading)
    }

    private var filmstrip: some View {
        let keys = frames.keys.sorted()
        let count = max(1, keys.count)
        return ZStack {
            Color.white.opacity(0.05)
            if keys.isEmpty {
                Shimmer()
            } else {
                HStack(spacing: 0) {
                    ForEach(keys, id: \.self) { k in
                        Image(nsImage: frames[k]!)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(count), height: stripHeight)
                            .clipped()
                    }
                }
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white)
            .frame(width: handleW, height: stripHeight + 4)
            .overlay(
                HStack(spacing: 2) {
                    Capsule().fill(.black.opacity(0.35)).frame(width: 1.5, height: 14)
                    Capsule().fill(.black.opacity(0.35)).frame(width: 1.5, height: 14)
                }
            )
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func ruler(_ x: @escaping (Double) -> CGFloat) -> some View {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { CGFloat($0 / duration) * width >= 64 } ?? 3600
        let ticks = Array(stride(from: 0, through: duration, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Time.format(tick, tenths: step < 1))
                        .font(.ui(10.5, .medium).monospacedDigit()).foregroundStyle(Theme.text3)
                        .fixedSize()
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 4)
                }
                .offset(x: x(tick))
            }
        }
        .frame(width: width, height: 20, alignment: .topLeading)
    }
}

/// AVPlayerLayer without the system transport controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class View: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.wantsLayer = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
