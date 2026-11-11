# dwn↓

**Download anything on the internet.** Videos, songs, playlists and transcripts from YouTube, TikTok, Instagram, X, SoundCloud and over a thousand other sites — straight to your computer. No accounts, no servers.

Dwn is a desktop app for **macOS** (native SwiftUI) and **Windows** (Electron). Both run the same local download engine built on [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org) and, for cloud drives, [rclone](https://rclone.org).

## Download

Get the latest version from **[Releases](https://github.com/YuvrajxGarg/dwn/releases/latest)**:

| Platform | File | Notes |
|---|---|---|
| macOS 14+ (Apple silicon) | `Dwn-mac.zip` | Unzip and move **Dwn** to Applications. The app isn't notarized yet: the first time, right-click it → **Open** → **Open**. |
| Windows 10/11 (64-bit) | `Dwn-Setup-x.y.z.exe` | Run the installer. If SmartScreen appears, click **More info** → **Run anyway**. |

Dwn checks this repository's releases for updates, notifies you when a new version is out, and installs it with one click.

## Features

- **Paste and go** — paste a link, or drop one anywhere in the window. YouTube previews appear instantly.
- **Formats** — H.264, HEVC, ProRes or the original file for video (up to 4K/8K); MP3, AAC or WAV for audio; transcripts from captions.
- **Sections** — trim before you download with a filmstrip timeline, frame-accurate start/end, chapters and "most replayed".
- **Cloud drives** — a Cloud tab for Google Drive, Dropbox, OneDrive, Box and pCloud: browse your files, everything shared with you (grouped by person) and shared folder links, then drag whole folders to your computer. They download file by file, never as Google Drive's split 2 GB zips. Drag files the other way to upload.
- **Bulk download** — paste many links or a text/CSV file; playlists, albums and channels expand automatically.
- **Quick download panel** — a global shortcut (⌥⌘D / Alt+Shift+D, customizable) opens a small panel over any app with the copied link ready.
- **Menu bar / system tray** — keep Dwn one click away, even with the window closed.
- **Instrumentals** and **Spotify → YouTube** matching for songs.
- **YouTube sign-in** — optionally uses the login from your browser when YouTube asks to confirm you're not a bot.
- **Cover art, metadata and subtitles** embedded in the files.
- **Updates** for the app (from GitHub Releases) and for yt-dlp (from PyPI).

## Repository layout

```
engine/    Python download engine (yt-dlp + FFmpeg behind a token-guarded local HTTP API)
app/       macOS app (SwiftUI), built with Swift Package Manager
windows/   Windows app (Electron), same engine bundled as a sidecar
build.sh   macOS build script
VERSION    the app version used by builds
.github/workflows/release.yml   builds both apps and attaches them to a release
```

## Building

**macOS** (needs Xcode or the Command Line Tools, [uv](https://docs.astral.sh/uv/), FFmpeg and, for the Cloud tab, rclone — `brew install rclone`):

```bash
./build.sh --install        # builds dist/Dwn.app and copies it to ~/Applications
```

**Windows app, for development on any OS** (needs Node.js 20+ and the engine's virtualenv from the macOS build or `uv venv engine/.venv && uv pip install -r engine/requirements.txt`):

```bash
cd windows && npm install && npm start
```

The Windows installer itself is built on GitHub Actions (`windows-latest`).

## Releasing

1. Bump `VERSION` (e.g. `1.0.1`) and commit.
2. Tag and push: `git tag v1.0.1 && git push origin v1.0.1`.
3. The **Release** workflow builds both apps and uploads them to the `v1.0.1` release. Installed copies pick it up on their next update check.

## Responsible use

Dwn is for downloading content you have the right to download — your own uploads, public-domain and Creative Commons works, or anything the rights holder allows. Respect copyright and each site's terms of service.

## License

[MIT](LICENSE). Dwn bundles yt-dlp (Unlicense), FFmpeg (GPL builds), Deno (MIT) and rclone (MIT) in its release builds.
