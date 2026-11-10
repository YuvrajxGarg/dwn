import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FormatSettings().tabItem { Label("Formats", systemImage: "film") }
            QuickSettings().tabItem { Label("Shortcut & menu bar", systemImage: "command") }
            EngineSettings().tabItem { Label("Engine", systemImage: "engine.combustion") }
            UpdateSettings(updater: model.updater).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Save downloads to") {
                HStack {
                    Text((model.prefs.folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseFolder() }
                }
            }
            Stepper("Downloads at once: \(model.prefs.concurrency)",
                    value: Binding(get: { model.prefs.concurrency }, set: { v in model.updatePrefs { $0.concurrency = v } }),
                    in: 1...8)
            Section("YouTube sign-in") {
                SignInPanel(compact: true)
                if !model.prefs.browserCookies.isEmpty {
                    Button("Stop using browser logins") { model.updatePrefs { $0.browserCookies = "" } }
                }
            }
            Section {
                Button("Show the welcome tour again") { model.onboarded = false }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.prefs.folder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            if FileManager.default.isWritableFile(atPath: url.path) {
                model.updatePrefs { $0.folder = url.path }
            } else {
                model.toast("That folder can't be written to. Pick another.", error: true)
            }
        }
    }
}

private struct FormatSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Video", selection: Binding(get: { model.prefs.videoFormat }, set: { v in model.updatePrefs { $0.videoFormat = v } })) {
                ForEach(Formats.video, id: \.id) { f in
                    VStack(alignment: .leading) { Text(f.name); Text(f.note).font(.caption).foregroundStyle(.secondary) }.tag(f.id)
                }
            }
            .pickerStyle(.radioGroup)
            Picker("Audio", selection: Binding(get: { model.prefs.audioFormat }, set: { v in model.updatePrefs { $0.audioFormat = v } })) {
                ForEach(Formats.audio, id: \.id) { f in
                    VStack(alignment: .leading) { Text(f.name); Text(f.note).font(.caption).foregroundStyle(.secondary) }.tag(f.id)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle("Embed cover art", isOn: Binding(get: { model.prefs.embedThumbnail }, set: { v in model.updatePrefs { $0.embedThumbnail = v } }))
            Toggle("Embed metadata (title, artist, upload date, chapters)",
                   isOn: Binding(get: { model.prefs.embedMetadata }, set: { v in model.updatePrefs { $0.embedMetadata = v } }))
            Toggle("Embed subtitles in videos", isOn: Binding(get: { model.prefs.embedSubs }, set: { v in model.updatePrefs { $0.embedSubs = v } }))
        }
        .formStyle(.grouped)
    }
}

private struct QuickSettings: View {
    @EnvironmentObject var model: AppModel

    private let bookmarklet = "javascript:location.href='dwn://download?url='+encodeURIComponent(location.href)"

    var body: some View {
        Form {
            Section("Global shortcut") {
                Toggle("Use a global shortcut", isOn: $model.hotkeyEnabled)
                LabeledContent("Shortcut") { ShortcutRecorder() }
                    .disabled(!model.hotkeyEnabled)
                Picker("Pressing it", selection: $model.shortcutAction) {
                    Text("Opens the quick download panel").tag("panel")
                    Text("Downloads the copied link right away").tag("instant")
                }
                .disabled(!model.hotkeyEnabled)
                Picker("Quick panel appears", selection: $model.panelPosition) {
                    Text("Top right, under the menu bar").tag("top")
                    Text("Bottom right").tag("bottom")
                }
                Text("Works in any app. Click the shortcut to record a new one; Delete resets it to ⌥⌘D.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show Dwn in the menu bar", isOn: $model.menuBarEnabled)
                Toggle("Hide the Dock icon", isOn: $model.hideDock)
                    .disabled(!model.menuBarEnabled)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("Click the menu bar icon for the quick download panel. Closing the window or choosing Quit from the Dock keeps Dwn running there; choose Quit Dwn in the menu bar menu (or ⌥⌘Q) to quit completely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser") {
                LabeledContent("Send to Dwn bookmarklet") {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bookmarklet, forType: .string)
                        model.toast("Copied. Make a new bookmark and paste it as the address.")
                    }
                }
                Text("Click the bookmark on any video page to download that video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EngineSettings: View {
    @EnvironmentObject var model: AppModel
    @Local private var checking = false
    @Local private var result: String?

    var body: some View {
        Form {
            LabeledContent("Engine", value: model.health?.engine ?? "–")
            LabeledContent("yt-dlp", value: model.health?.ytdlp ?? "–")
            LabeledContent("ffmpeg", value: model.health?.ffmpeg.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Missing (conversions won't work)")
            LabeledContent("YouTube helper", value: model.health?.jsRuntime ?? "Missing (YouTube may fail)")
            HStack {
                Button {
                    checking = true
                    Task {
                        result = await model.updateEngine()
                        checking = false
                        model.health = try? await model.api?.call("health")
                    }
                } label: { Text(checking ? "Checking…" : "Get the newest yt-dlp") }
                    .disabled(checking)
                Button("Restart Engine") { model.engine.restart() }
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Engine.logURL]) }
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
            Text("If a site stops working, update yt-dlp.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
