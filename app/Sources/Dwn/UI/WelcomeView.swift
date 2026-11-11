import SwiftUI
import UserNotifications

/// First-run setup: intro, default formats, save folder, YouTube sign-in, quick download, cloud drives.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Local private var step = 0
    @Local private var forward = true
    @Local private var notifStatus: UNAuthorizationStatus = .notDetermined

    private let steps = ["Welcome", "Formats", "Folder", "Sign in", "Shortcuts", "Cloud", "Done"]
    private let bookmarklet = "javascript:location.href='dwn://download?url='+encodeURIComponent(location.href)"

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ZStack {
                    ScrollView(showsIndicators: false) {
                        page.frame(minHeight: 470)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                            removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
                }
                .frame(maxWidth: 520, maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
        .task { notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Theme.accent : Theme.raised)
                    .frame(width: i == step ? 26 : 8, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            }
        }
        .frame(height: 30)
        .opacity(step == 0 ? 0 : 1)
    }

    private var footer: some View {
        HStack {
            if step > 0 && step < steps.count - 1 {
                Button("Back") { go(step - 1) }
                    .buttonStyle(.plain).font(.ui(13.5, .medium)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if step == 3 && model.prefs.browserCookies.isEmpty {
                Button("Skip for now") { go(step + 1) }
                    .buttonStyle(.plain).font(.ui(13.5, .medium)).foregroundStyle(Theme.text2)
                    .padding(.trailing, 14)
            }
            Button(primaryTitle) {
                if step == steps.count - 1 { finish() } else { go(step + 1) }
            }
            .buttonStyle(PrimaryButtonStyle(height: 42))
            .frame(width: 180)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get started"
        case steps.count - 1: "Start downloading"
        default: "Continue"
        }
    }

    private func go(_ s: Int) {
        forward = s > step
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = max(0, min(s, steps.count - 1)) }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.45)) { model.onboarded = true }
    }

    // MARK: pages

    @ViewBuilder private var page: some View {
        switch step {
        case 0: intro
        case 1: formats
        case 2: folder
        case 3: signIn
        case 4: shortcuts
        case 5: cloud
        default: done
        }
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.ui(26, .bold)).foregroundStyle(Theme.text)
            Text(sub).font(.ui(14)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var intro: some View {
        VStack(spacing: 26) {
            Spacer()
            Wordmark(size: 76)
            VStack(spacing: 10) {
                Text("Download anything on the internet.")
                    .font(.ui(19, .semibold)).foregroundStyle(Theme.text)
                Text("Videos, songs, playlists and transcripts from YouTube, TikTok, Instagram, X, SoundCloud and over a thousand other sites. Straight to your Mac, no accounts, no servers.")
                    .font(.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 10) {
                fact("bolt.fill", "Fast", "Downloads run side by side")
                fact("scissors", "Precise", "Save just the part you want")
                fact("lock.fill", "Private", "Nothing leaves your Mac")
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    private func fact(_ icon: String, _ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.accent).font(.ui(14, .semibold))
            Text(t).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
            Text(d).font(.ui(12)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Choose your default formats", "Every download is saved this way. Change it any time in Settings.")
            formatGroup("Video", Formats.video, model.prefs.videoFormat) { v in model.updatePrefs { $0.videoFormat = v } }
            formatGroup("Audio", Formats.audio, model.prefs.audioFormat) { v in model.updatePrefs { $0.audioFormat = v } }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func formatGroup(_ label: String, _ list: [(id: String, name: String, note: String)], _ selected: String,
                             _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).sectionLabel()
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, f in
                    Button { set(f.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: f.id == selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(f.id == selected ? Theme.accent : Theme.text3)
                                .font(.ui(15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.ui(14, .medium)).foregroundStyle(Theme.text)
                                Text(f.note).font(.ui(12)).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(f.id == selected ? Theme.raised : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < list.count - 1 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .card(radius: 14)
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Choose where Dwn saves downloads", "A folder in Downloads works well. You can pick a different one for any bulk download.")
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: FileManager.default.fileExists(atPath: model.prefs.folder)
                                                       ? model.prefs.folder : NSHomeDirectory() + "/Downloads"))
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text((model.prefs.folder as NSString).lastPathComponent).font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                    Text((model.prefs.folder as NSString).abbreviatingWithTildeInPath)
                        .font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Change…") { model.chooseFolder() }.buttonStyle(QuietButtonStyle())
            }
            .padding(16)
            .card()
            if let free = model.freeBytes {
                Label("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this drive",
                      systemImage: "internaldrive")
                    .font(.ui(12.5)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.top, 28)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Sign in to YouTube, just in case",
                  "Every so often, YouTube blocks downloads until it's sure a real person is behind them. Pick the browser where you're signed in to YouTube and Dwn will use that login when it needs to. Most downloads work without it.")
            SignInPanel()
        }
        .padding(.top, 28)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Download from anywhere", "Start downloads without switching to Dwn.")
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "command").foregroundStyle(Theme.text2).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Global shortcut").font(.ui(14, .medium)).foregroundStyle(Theme.text)
                        Text("Opens a small download panel over any app, with the copied link ready.")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    ShortcutRecorder()
                }
                .padding(14).card()

                OptionRow(icon: "menubar.arrow.up.rectangle", title: "Show in the menu bar",
                          detail: "Keeps Dwn one click away, even with the window closed.",
                          isOn: $model.menuBarEnabled)
                    .padding(14).card()

                HStack(spacing: 12) {
                    Image(systemName: "bookmark.fill").foregroundStyle(Theme.text2).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Send to Dwn bookmarklet").font(.ui(14, .medium)).foregroundStyle(Theme.text)
                        Text("Drag it to your bookmarks bar, then click it on any video page.")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Text("Send to Dwn")
                        .font(.ui(12.5, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                        .draggable(URL(string: bookmarklet)!)
                        .help("Drag to your bookmarks bar")
                    Button { copy(bookmarklet) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(IconButtonStyle(size: 30))
                        .help("Copy the bookmarklet's code, to paste as a bookmark's address")
                }
                .padding(14).card()

                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(Theme.text2).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications").font(.ui(14, .medium)).foregroundStyle(Theme.text)
                        Text("When a download finishes while Dwn is in the background.")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    switch notifStatus {
                    case .authorized, .provisional:
                        Label("On", systemImage: "checkmark").font(.ui(12.5, .semibold)).foregroundStyle(Theme.accent)
                    case .denied:
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .buttonStyle(QuietButtonStyle(height: 30))
                    default:
                        Button("Allow") {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                                notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                            }
                        }
                        .buttonStyle(QuietButtonStyle(height: 30))
                    }
                }
                .padding(14).card()
            }
        }
        .padding(.top, 28)
    }

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Whole folders from Google Drive and Dropbox",
                  "Connect an account in the Cloud tab to see your files and everything shared with you, grouped by person. Drag a folder to your Mac and it arrives file by file, never as split 2 GB zips.")
            // A small picture of the Cloud tab: this Mac on the left, the cloud on the right.
            HStack(spacing: 10) {
                miniPane(icon: AnyView(Image(systemName: "laptopcomputer").font(.ui(12, .medium)).foregroundStyle(Theme.text2)),
                         title: "This Mac", rows: [("Client Footage 2026", true), ("A001_C004.mov", false)])
                Image(systemName: "arrow.left").font(.ui(13, .bold)).foregroundStyle(Theme.accent)
                miniPane(icon: AnyView(ServiceIcon(type: "drive", size: 20)),
                         title: "Shared with me", rows: [("Client Footage 2026", true), ("Wedding RAW", true)])
            }
            HStack(spacing: 8) {
                ForEach(["drive", "dropbox", "onedrive", "box", "pcloud"], id: \.self) { ServiceIcon(type: $0, size: 24) }
                Text("Google Drive, Dropbox, OneDrive, Box and pCloud").font(.ui(12)).foregroundStyle(Theme.text3)
                    .padding(.leading, 4)
            }
            Button {
                model.section = "cloud"
                finish()
            } label: { Label("Open the Cloud tab", systemImage: "cloud") }
                .buttonStyle(QuietButtonStyle(height: 34))
        }
        .padding(.top, 28)
    }

    private func miniPane(icon: AnyView, title: String, rows: [(String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon
                Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.1 ? "folder.fill" : "film").font(.ui(10.5))
                        .foregroundStyle(r.1 ? Theme.accent : Theme.text3)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(r.1 ? Theme.accent.opacity(0.10) : Color.white.opacity(0.06)))
                    Text(r.0).font(.ui(11.5, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }

    private var done: some View {
        VStack(spacing: 22) {
            Spacer()
            LogoMark(size: 84)
            VStack(spacing: 8) {
                Text("You're all set").font(.ui(26, .bold)).foregroundStyle(Theme.text)
                Text("Paste a link, drop one anywhere in the window, or press \(model.shortcut.display) in any app.")
                    .font(.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                summary("film", "Video", Formats.name(model.prefs.videoFormat))
                summary("waveform", "Audio", Formats.name(model.prefs.audioFormat))
                summary("folder", "Saving to", (model.prefs.folder as NSString).abbreviatingWithTildeInPath)
                summary("person.crop.circle", "YouTube login",
                        Browser.named(model.prefs.browserCookies)?.name ?? "Off")
            }
            .padding(16)
            .frame(width: 380)
            .card()
            Spacer()
        }
    }

    private func summary(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(Theme.text3).frame(width: 18)
            Text(k).foregroundStyle(Theme.text2)
            Spacer()
            Text(v).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.ui(13))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        model.toast("Copied. Make a new bookmark and paste it as the address.")
    }
}
