import SwiftUI

/// The main card: paste a link, see what it is, pick a format and options, download.
struct ComposerView: View {
    @EnvironmentObject var model: AppModel
    @Local private var info: LinkInfo?
    @Local private var looking = false
    @Local private var lookupError: String?
    @Local private var clipboardLink: String?
    @Local private var optionsOpen = UserDefaults.standard.object(forKey: "optionsOpen") as? Bool ?? true
    @FocusState private var focused: Bool

    private var link: String { model.composerText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { looksLikeLink(link) }
    private var section: SectionChoice? {
        guard let c = model.sectionChoice, valid, c.url == normalizeLink(link) || c.url == info?.url else { return nil }
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            linkField
            preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Format").sectionLabel()
                DwnTabs(items: [
                    TabItem(id: "video", title: "Video", icon: "film"),
                    TabItem(id: "audio", title: "Audio", icon: "waveform"),
                    TabItem(id: "transcript", title: "Transcript", icon: "text.alignleft"),
                ], selection: $model.tab, height: M.controlLarge)
            }
            qualitySection
            if model.tab != "transcript" { options }
            actions
        }
        .padding(14)
        .card(Theme.card, radius: 16)
        .task(id: link) {
            if link.isEmpty { checkClipboard() }
            await lookup()
        }
        .onAppear { checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkClipboard()
        }
    }

    // MARK: link

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3)
                    .frame(width: M.iconColumn)
                TextField("", text: $model.composerText, prompt: Text("Paste a link").foregroundStyle(Theme.text3))
                    .textFieldStyle(.plain)
                    .font(.ui(13.5, .medium))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { Task { await start() } }
                if model.composerText.isEmpty {
                    Button {
                        model.composerText = NSPasteboard.general.string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").font(.ui(12, .semibold))
                    }
                    .buttonStyle(QuietButtonStyle(height: 28))
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                } else {
                    Button { model.composerText = "" } label: { Image(systemName: "xmark.circle.fill").font(.ui(13)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: M.controlLarge)
            .controlFill()
            .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .strokeBorder(Color.white.opacity(focused ? 0.16 : 0)))
            .animation(.easeOut(duration: 0.15), value: focused)

            if let clipboardLink, link.isEmpty {
                Button { model.composerText = clipboardLink } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.ui(10, .semibold))
                        Text("Use copied link").fontWeight(.medium)
                        Text(shortLink(clipboardLink)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.ui(12))
                    .foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if !link.isEmpty && !valid {
            Text("That doesn't look like a link. Paste the full address, like https://…")
                .font(.ui(12.5)).foregroundStyle(Theme.warn)
        } else if looking && info == nil {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.raised).frame(width: 88, height: 50).overlay(Shimmer())
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Theme.raised).frame(height: 10).overlay(Shimmer()).clipShape(Capsule())
                    Capsule().fill(Theme.raised).frame(width: 110, height: 8).overlay(Shimmer()).clipShape(Capsule())
                }
            }
            .padding(10).card(Theme.bg.opacity(0.5), radius: 14)
        } else if let lookupError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                Text("Couldn't read that link. You can still try downloading it.\n\(lookupError)")
                    .font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(4)
            }
        } else if let info {
            LinkCard(info: info, showTools: model.tab != "transcript",
                     onSection: { model.sectionTarget = info },
                     onInstrumental: {
                         Task { await model.download(normalizeLink(link), info: info, kind: "audio", mode: "instrumental") }
                     },
                     section: section,
                     onClearSection: { model.sectionChoice = nil })
        }
    }

    // MARK: format

    @ViewBuilder private var qualitySection: some View {
        switch model.tab {
        case "video":
            VStack(alignment: .leading, spacing: 8) {
                Text("Quality").sectionLabel()
                DwnDropdown(options: Formats.heights.map { ($0.0, $0.1, codecShort) },
                            selection: Binding(get: { model.prefs.maxHeight },
                                               set: { v in model.updatePrefs { $0.maxHeight = v } }),
                            icon: "aspectratio", height: M.controlLarge)
            }
        case "audio":
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio format").sectionLabel()
                DwnDropdown(options: Formats.audio.map { ($0.id, $0.name, nil) },
                            selection: Binding(get: { model.prefs.audioFormat },
                                               set: { v in model.updatePrefs { $0.audioFormat = v } }),
                            icon: "music.note", height: M.controlLarge)
            }
        default:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "captions.bubble").foregroundStyle(Theme.text2)
                Text("Saves the video's captions as a text file, with the same name as the video.")
                    .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .card(Theme.bg.opacity(0.5), radius: 12)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    optionsOpen.toggle()
                    UserDefaults.standard.set(optionsOpen, forKey: "optionsOpen")
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Options").sectionLabel()
                    Spacer()
                    Image(systemName: "chevron.down").font(.ui(10, .bold)).foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(optionsOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if optionsOpen {
                VStack(spacing: 12) {
                    OptionRow(icon: "photo", title: "Embed cover art", isOn: pref(\.embedThumbnail))
                    OptionRow(icon: "tag", title: "Embed metadata", isOn: pref(\.embedMetadata))
                    if model.tab == "video" {
                        OptionRow(icon: "captions.bubble", title: "Embed subtitles", isOn: pref(\.embedSubs))
                        OptionRow(icon: "film.stack", title: "ProRes for editing", isOn: prores)
                    }
                    OptionRow(icon: "key", title: loginTitle, isOn: browserLogin)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var codecShort: String {
        ["h264": "H.264", "hevc": "HEVC", "prores": "ProRes", "original": "Original"][model.prefs.videoFormat] ?? ""
    }

    private func pref(_ kp: WritableKeyPath<Prefs, Bool>) -> Binding<Bool> {
        Binding(get: { model.prefs[keyPath: kp] }, set: { v in model.updatePrefs { $0[keyPath: kp] = v } })
    }

    private var prores: Binding<Bool> {
        Binding(get: { model.prefs.videoFormat == "prores" }, set: { on in
            if on {
                UserDefaults.standard.set(model.prefs.videoFormat, forKey: "codecBeforeProRes")
                model.updatePrefs { $0.videoFormat = "prores" }
            } else {
                let prev = UserDefaults.standard.string(forKey: "codecBeforeProRes") ?? "h264"
                model.updatePrefs { $0.videoFormat = prev == "prores" ? "h264" : prev }
            }
        })
    }

    private var loginTitle: String {
        if let b = Browser.named(model.prefs.browserCookies) { return "Use \(b.name) logins" }
        if let b = model.installedBrowsers.first { return "Use \(b.name) logins" }
        return "Use browser logins"
    }

    private var browserLogin: Binding<Bool> {
        Binding(get: { !model.prefs.browserCookies.isEmpty }, set: { on in
            if on { model.showSignIn = true } else { model.updatePrefs { $0.browserCookies = "" } }
        })
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button { Task { await start() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.tab == "transcript" ? "text.alignleft" : "arrow.down")
                        .font(.ui(13, .bold))
                    Text(primaryTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!valid)

        }
        .animation(.easeOut(duration: 0.2), value: valid)
    }

    private var primaryTitle: String {
        if model.tab == "transcript" { return "Save transcript" }
        if section != nil { return "Download section" }
        if info?.isPlaylist == true, let n = info?.count { return "Download all \(n)" }
        return "Download"
    }

    private func lookup() async {
        if let c = model.sectionChoice, c.url != normalizeLink(link) { model.sectionChoice = nil }
        info = nil
        lookupError = nil
        guard valid else { return }
        let target = normalizeLink(link)
        // YouTube: show the thumbnail at once and the title from oEmbed (~0.2 s),
        // while the full lookup (~3 s) fills in duration, chapters and the rest.
        let quick = FastPreview.quickInfo(link)
        if let quick {
            info = quick
            Task {
                if let o = await FastPreview.oembed(target), info?.url == target, info?.title == nil {
                    withAnimation(.easeOut(duration: 0.15)) { info?.title = o.title; info?.uploader = o.author }
                }
            }
        } else {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        looking = true
        defer { looking = false }
        do {
            let full = try await model.lookup(target)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { info = FastPreview.merge(quick: info, full: full) } }
        } catch {
            if !Task.isCancelled && quick == nil { lookupError = error.localizedDescription }
        }
    }

    private func start() async {
        guard valid else { return }
        let url = normalizeLink(link)
        if model.tab == "transcript" {
            await model.transcript(url)
            return
        }
        if info?.isPlaylist == true {
            model.bulkPrefill = url
            model.showBulk = true
            return
        }
        if info?.isLive == true {
            model.toast("This stream is live. Download it once it has ended.", error: true)
            return
        }
        let cut = section
        if await model.download(url, info: info, kind: model.tab, start: cut?.start, end: cut?.end) {
            model.composerText = ""
            model.sectionChoice = nil
            info = nil
        }
    }

    private func checkClipboard() {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        clipboardLink = looksLikeLink(s) ? s.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func shortLink(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")
    }
}

struct LinkCard: View {
    var info: LinkInfo
    var showTools = false
    var onSection: () -> Void = {}
    var onInstrumental: () -> Void = {}
    var section: SectionChoice? = nil
    var onClearSection: () -> Void = {}

    private var site: String? {
        let names = ["Youtube": "YouTube", "YoutubeTab": "YouTube", "Twitter": "X", "Tiktok": "TikTok",
                     "TikTok": "TikTok", "Soundcloud": "SoundCloud", "Instagram": "Instagram", "Vimeo": "Vimeo"]
        return info.site.map { names[$0] ?? $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumb(url: info.thumbnail)
                .frame(width: 92, height: 52)
                .overlay(alignment: .bottomTrailing) {
                    if let d = info.duration, info.isPlaylist != true {
                        Text(Time.format(d)).font(.ui(10, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.7)))
                            .padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                if let title = info.title {
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(showTools ? 1 : 2)
                } else {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 10).overlay(Shimmer()).clipShape(Capsule())
                        .padding(.vertical, 3)
                }
                HStack(spacing: 5) {
                    if let u = info.uploader { Text(u).lineLimit(1) }
                    if let s = site { Text("· " + s) }
                    if info.isPlaylist == true { Text("· \(info.count ?? 0) items") }
                    if info.isLive { Text("· Live").foregroundStyle(Theme.danger) }
                }
                .font(.ui(11.5)).foregroundStyle(Theme.text3)
                if showTools && info.isPlaylist != true {
                    HStack(spacing: 6) {
                        if let section {
                            HStack(spacing: 5) {
                                Button(action: onSection) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "scissors").font(.ui(10, .bold))
                                        Text("\(Time.format(section.start))–\(Time.format(section.end))").monospacedDigit()
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Edit the section")
                                Button(action: onClearSection) { Image(systemName: "xmark").font(.ui(8.5, .bold)) }
                                    .buttonStyle(.plain).help("Download the whole video instead")
                            }
                            .font(.ui(11.5, .semibold))
                            .foregroundStyle(.black)
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent))
                        } else {
                            pill("Section", "scissors", action: onSection)
                                .disabled(info.isLive)
                                .help("Download just part of the video")
                        }
                        pill("Instrumental", "music.note", action: onInstrumental)
                            .help("Find this song's instrumental on YouTube and download it")
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .controlFill()
    }

    private func pill(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.ui(10, .bold))
                Text(t)
            }
                .font(.ui(11.5, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

