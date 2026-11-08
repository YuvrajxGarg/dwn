import SwiftUI

/// Lets Dwn use the YouTube login from a browser the user already has.
/// Used in first-run setup and whenever YouTube blocks a download.
struct SignInPanel: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    var onDone: (() -> Void)? = nil

    @Local private var checking: String?
    @Local private var result: LoginCheck?
    @Local private var checkedBrowser: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let browsers = model.installedBrowsers
            if browsers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                    Text("Needs Chrome, Brave, Edge or Firefox. Install one and sign in to YouTube there, then come back.")
                        .font(.ui(13)).foregroundStyle(Theme.text2)
                }
                .padding(14).card()
            } else {
                VStack(spacing: 8) {
                    ForEach(browsers) { b in browserRow(b) }
                }
            }

            if checking != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Your Mac may ask for its password. Choose Always Allow.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2)
                }
            } else if let result, let browser = checkedBrowser.flatMap(Browser.named) {
                resultView(result, browser)
            }

            Text("Your login stays on this Mac and is sent only to YouTube. Dwn has no servers.")
                .font(.ui(11.5)).foregroundStyle(Theme.text3)
        }
    }

    private func browserRow(_ b: Browser) -> some View {
        let active = model.prefs.browserCookies == b.id
        return Button {
            Task { await check(b) }
        } label: {
            HStack(spacing: 12) {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in with \(b.name)").font(.ui(14, .medium)).foregroundStyle(Theme.text)
                    Text(active ? "In use for YouTube downloads" : "Uses your YouTube login from \(b.name)")
                        .font(.ui(11.5)).foregroundStyle(active ? Theme.accent : Theme.text3)
                }
                Spacer()
                if checking == b.id {
                    ProgressView().controlSize(.small)
                } else if active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.ui(17))
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.text3).font(.ui(12, .semibold))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, compact ? 10 : 12)
            .card(active ? Theme.raised : Theme.card, radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(checking != nil)
    }

    @ViewBuilder private func resultView(_ r: LoginCheck, _ b: Browser) -> some View {
        if r.ok && r.signedIn == true {
            Label("Found your YouTube login in \(b.name). Downloads that YouTube blocks will now work.",
                  systemImage: "checkmark.seal.fill")
                .font(.ui(12.5, .medium)).foregroundStyle(Theme.accent)
        } else if r.ok {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(b.name) isn't signed in to YouTube.", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.ui(12.5, .medium)).foregroundStyle(Theme.warn)
                HStack(spacing: 8) {
                    Button("Sign in to YouTube in \(b.name)") { model.openYouTube(in: b) }
                        .buttonStyle(QuietButtonStyle(height: 32))
                    Button("Check again") { Task { await check(b) } }
                        .buttonStyle(QuietButtonStyle(height: 32))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(r.message ?? "Couldn't read that browser's login.", systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(12.5, .medium)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if r.reason == "permission" {
                        Button("Open Full Disk Access settings") { FullDiskAccess.open() }
                            .buttonStyle(QuietButtonStyle(height: 32))
                    }
                    Button("Try again") { Task { await check(b) } }.buttonStyle(QuietButtonStyle(height: 32))
                }
                if r.reason == "permission" {
                    Text("Turn on Dwn in the list (use + to add it from Applications if it isn't there), then come back and try again.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func check(_ b: Browser) async {
        checking = b.id
        result = nil
        let r = await model.checkLogin(b.id)
        checking = nil
        checkedBrowser = b.id
        result = r
        if r.ok {
            // Even without a YouTube login the cookies help, so keep the browser selected.
            model.updatePrefs { $0.browserCookies = b.id }
            if r.signedIn == true { onDone?() }
        }
    }
}

/// Shown when a download failed because YouTube wants a signed-in user.
struct SignInSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to YouTube").font(.ui(20, .bold)).foregroundStyle(Theme.text)
                    Text("Every so often, YouTube blocks downloads until it's sure a real person is behind them. Signing in with the account you already use in your browser fixes it.")
                        .font(.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            SignInPanel(compact: true) {
                model.retrySignInFailures()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
            }
            HStack {
                if !model.prefs.browserCookies.isEmpty {
                    Button("Stop using browser logins") { model.updatePrefs { $0.browserCookies = "" } }
                        .buttonStyle(.plain).font(.ui(12.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Not now") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                if !model.prefs.browserCookies.isEmpty {
                    Button("Retry downloads") { model.retrySignInFailures(); dismiss() }
                        .buttonStyle(PrimaryButtonStyle(height: 36)).frame(width: 150)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.sidebar)
    }
}

enum FullDiskAccess {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
