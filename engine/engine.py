"""Dwn download engine.

A small local HTTP server wrapping yt-dlp. The macOS app launches it as a child
process, passes a random token in DWN_TOKEN, and waits for the line
``DWN_ENGINE_READY <port>`` on stdout. Every request must carry the token in
the ``X-Dwn-Token`` header. The engine exits when its stdin closes, so it never
outlives the app.
"""

from __future__ import annotations

import concurrent.futures as cf
import glob
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENGINE_VERSION = "1.0.0"
IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform.startswith("win")


def _support_dir() -> str:
    if IS_MAC:
        return os.path.expanduser("~/Library/Application Support/Dwn")
    if IS_WIN:
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Dwn")
    return os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "Dwn")


def _cache_dir() -> str:
    if IS_MAC:
        return os.path.expanduser("~/Library/Caches/Dwn")
    if IS_WIN:
        return os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "Dwn", "Cache")
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "Dwn")


SUPPORT = _support_dir()
CACHE = _cache_dir()
UPDATES = os.path.join(SUPPORT, "ytdlp")
os.makedirs(SUPPORT, exist_ok=True)

# A newer yt-dlp installed by /update-ytdlp lives as a wheel (a zip) in
# UPDATES. Wheels of pure-Python packages import straight from the zip.
_wheels = sorted(glob.glob(os.path.join(UPDATES, "yt_dlp-*.whl")))
if _wheels:
    sys.path.insert(0, _wheels[-1])

import yt_dlp  # noqa: E402
from yt_dlp.utils import download_range_func  # noqa: E402

TOKEN = os.environ.get("DWN_TOKEN", "")
PREFS_PATH = os.path.join(SUPPORT, "prefs.json")
HISTORY_PATH = os.path.join(SUPPORT, "history.json")

DEFAULT_PREFS = {
    "folder": os.path.expanduser("~/Downloads/Dwn"),
    "kind": "video",            # video | audio
    "video_format": "h264",     # h264 | hevc | prores | original
    "audio_format": "mp3",      # mp3 | aac | wav
    "max_height": 0,            # 0 = best available
    "concurrency": 3,
    "embed_metadata": True,
    "embed_thumbnail": True,
    "embed_subs": False,
    "browser_cookies": "",      # "", chrome, firefox, brave, edge
}

lock = threading.RLock()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------- tools

def which(name: str) -> str | None:
    """Bundled tools first (engine/bin), then common install places, then PATH."""
    exe = name + ".exe" if IS_WIN else name
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    cands = [os.path.join(here, "bin", exe), os.path.join(getattr(sys, "_MEIPASS", here), "bin", exe)]
    if IS_MAC:
        cands += [f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}"]
    for cand in cands:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return shutil.which(name)


def js_runtime() -> tuple[str, str] | None:
    for name in ("deno", "node", "bun"):
        p = which(name)
        if p:
            return name, p
    nvm = sorted(glob.glob(os.path.expanduser("~/.nvm/versions/node/*/bin/node"))) if not IS_WIN else []
    if nvm:
        return "node", nvm[-1]
    return None


FFMPEG = which("ffmpeg")


# --------------------------------------------------------------------------- storage

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


prefs = {**DEFAULT_PREFS, **load_json(PREFS_PATH, {})}
history: list[dict] = load_json(HISTORY_PATH, [])


def save_prefs():
    save_json(PREFS_PATH, prefs)


def add_history(entry: dict):
    with lock:
        history.insert(0, entry)
        del history[2000:]
        save_json(HISTORY_PATH, history)


# --------------------------------------------------------------------------- yt-dlp

def base_opts(extra: dict | None = None) -> dict:
    o = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "socket_timeout": 20,
        "retries": 5,
        "fragment_retries": 5,
        "concurrent_fragment_downloads": 4,
    }
    if FFMPEG:
        o["ffmpeg_location"] = FFMPEG
    rt = js_runtime()
    if rt:
        o["js_runtimes"] = {rt[0]: {"path": rt[1]}}
    if prefs.get("browser_cookies"):
        o["cookiesfrombrowser"] = (prefs["browser_cookies"],)
    if extra:
        o.update(extra)
    return o


def extract(url: str, flat=False) -> dict:
    opts = base_opts({"skip_download": True})
    if flat:
        opts["extract_flat"] = "in_playlist"
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.sanitize_info(ydl.extract_info(url, download=False))


_info_cache: dict[str, tuple[float, dict]] = {}


def extract_cached(url: str) -> dict:
    """Full extraction, reused for 30 minutes so the link preview, the section
    editor and its frames don't each pay for YouTube extraction again."""
    hit = _info_cache.get(url)
    if hit and time.time() - hit[0] < 1800:
        return hit[1]
    info = extract(url, flat=True)
    _info_cache[url] = (time.time(), info)
    if len(_info_cache) > 64:
        for k in sorted(_info_cache, key=lambda k: _info_cache[k][0])[:16]:
            _info_cache.pop(k, None)
    return info


def summarize(info: dict) -> dict:
    thumbs = info.get("thumbnails") or []
    thumb = info.get("thumbnail") or (thumbs[-1]["url"] if thumbs else None)
    entries = info.get("entries")
    return {
        "url": info.get("webpage_url") or info.get("original_url") or info.get("url"),
        "title": info.get("title") or info.get("id"),
        "uploader": info.get("uploader") or info.get("channel") or info.get("artist"),
        "duration": info.get("duration"),
        "thumbnail": thumb,
        "site": info.get("extractor_key"),
        "live_status": info.get("live_status"),
        "is_playlist": info.get("_type") == "playlist",
        "count": len(entries) if isinstance(entries, list) else None,
        "width": info.get("width"),
        "height": info.get("height"),
        "chapters": [
            {"title": c.get("title"), "start": c.get("start_time"), "end": c.get("end_time")}
            for c in (info.get("chapters") or [])
        ],
        "heatmap": [
            {"start": h.get("start_time"), "end": h.get("end_time"), "value": h.get("value")}
            for h in (info.get("heatmap") or [])
        ],
    }


# --------------------------------------------------------------------------- spotify

def spotify_lookup(url: str) -> dict | None:
    """Spotify pages carry the song and artist in their Open Graph tags."""
    if "open.spotify.com" not in url:
        return None
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    page = urllib.request.urlopen(req, timeout=15).read().decode("utf-8", "replace")

    def meta(prop):
        m = re.search(r'<meta[^>]+property="%s"[^>]+content="([^"]*)"' % re.escape(prop), page)
        return html.unescape(m.group(1)) if m else None

    title = meta("og:title")
    desc = meta("og:description") or ""
    artist = desc.split(" · ")[0] if " · " in desc else None
    return {"title": title, "artist": artist, "cover": meta("og:image")}


# --------------------------------------------------------------------------- jobs

class Cancelled(Exception):
    pass


class Job:
    def __init__(self, req: dict):
        self.id = uuid.uuid4().hex[:12]
        self.req = req
        self.url = req["url"]
        self.title = req.get("title") or self.url
        self.thumbnail = req.get("thumbnail")
        self.kind = req.get("kind") or prefs["kind"]
        self.format = req.get("format") or (
            prefs["video_format"] if self.kind == "video" else prefs["audio_format"])
        self.state = "queued"   # queued|running|converting|done|failed|cancelled
        self.stage = "Waiting for a free slot"
        self.progress = 0.0
        self.speed = None
        self.eta = None
        self.error = None
        self.error_code = None
        self.file = None
        self.created = time.time()
        self.cancel_flag = threading.Event()
        self.future = None
        self.batch = req.get("batch")

    def to_dict(self):
        return {k: getattr(self, k) for k in (
            "id", "url", "title", "thumbnail", "kind", "format", "state", "stage",
            "progress", "speed", "eta", "error", "error_code", "file", "created", "batch")} | {
            "start": self.req.get("start"), "end": self.req.get("end"),
            "mode": self.req.get("mode", "normal")}


jobs: dict[str, Job] = {}
executor = cf.ThreadPoolExecutor(max_workers=16)
slots = threading.BoundedSemaphore(16)
running_count = 0
slot_cv = threading.Condition()


def acquire_slot(job: Job):
    global running_count
    with slot_cv:
        while running_count >= max(1, int(prefs.get("concurrency", 3))):
            if job.cancel_flag.is_set():
                raise Cancelled()
            slot_cv.wait(0.5)
        running_count += 1


def release_slot():
    global running_count
    with slot_cv:
        running_count -= 1
        slot_cv.notify_all()


def format_selector(job: Job) -> tuple[str, dict]:
    h = int(job.req.get("max_height") or prefs.get("max_height") or 0)
    cap = f"[height<={h}]" if h else ""
    if job.kind == "audio":
        if job.format == "aac":
            return "ba[acodec^=mp4a]/ba[ext=m4a]/ba/b", {}
        return "ba/b", {}
    if job.format == "h264":
        return (f"bv*{cap}[vcodec^=avc1]+ba[acodec^=mp4a]/bv*{cap}[vcodec^=avc1]+ba/"
                f"bv*{cap}+ba/b{cap}/b"), {"merge_output_format": "mp4"}
    if job.format in ("hevc", "prores"):
        return f"bv*{cap}+ba/b{cap}/b", {"merge_output_format": "mkv"}
    return f"bv*{cap}+ba/b{cap}/b", {}


def probe_codec(path: str) -> str:
    """The first video stream's codec, read from ffmpeg's own stream summary
    (so the app doesn't need to ship ffprobe as well)."""
    if not FFMPEG:
        return ""
    try:
        err = subprocess.run([FFMPEG, "-hide_banner", "-i", path], capture_output=True, text=True,
                             timeout=30, encoding="utf-8", errors="replace").stderr
    except Exception:
        return ""
    for line in err.splitlines():
        m = re.search(r"Stream #\S+.*?: Video: (\w+)", line)
        if m and "attached pic" not in line:
            return m.group(1)
    return ""


def convert(job: Job, src: str) -> str:
    """Re-encode to the requested editing/playback format with VideoToolbox."""
    if not FFMPEG:
        return src
    root, _ = os.path.splitext(src)
    if job.format == "h264":
        if probe_codec(src) == "h264" and src.endswith(".mp4"):
            return src
        enc = ["-c:v", "h264_videotoolbox", "-b:v", "0", "-q:v", "65"] if IS_MAC else \
              ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
        dst, args = root + ".h264.mp4", [*enc, "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]
        job.stage = "Converting to H.264"
    elif job.format == "hevc":
        enc = ["-c:v", "hevc_videotoolbox", "-q:v", "60"] if IS_MAC else \
              ["-c:v", "libx265", "-preset", "fast", "-crf", "24", "-pix_fmt", "yuv420p"]
        dst, args = root + ".hevc.mp4", [*enc, "-tag:v", "hvc1",
                                         "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]
        job.stage = "Converting to HEVC"
    elif job.format == "prores":
        enc = ["-c:v", "prores_videotoolbox", "-profile:v", "hq"] if IS_MAC else \
              ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]
        dst, args = root + ".prores.mov", [*enc, "-c:a", "pcm_s16le"]
        job.stage = "Converting for editing"
    else:
        return src
    job.state, job.progress = "converting", 0.0
    maps = ["-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-c:s", "mov_text", "-map_metadata", "0"]
    if job.req.get("start") is not None or job.req.get("end") is not None:
        maps += ["-map_chapters", "-1"]
    proc = subprocess.Popen([FFMPEG, "-y", "-v", "error", "-i", src, *maps, *args, "-progress", "pipe:1", dst],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    dur = job.req.get("_duration") or 0
    for line in proc.stdout:
        if job.cancel_flag.is_set():
            proc.kill()
            raise Cancelled()
        if line.startswith("out_time_us=") and dur:
            try:
                job.progress = min(1.0, int(line.split("=")[1]) / 1e6 / dur)
            except ValueError:
                pass
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError("Conversion failed: " + proc.stderr.read()[-400:])
    os.remove(src)
    final = re.sub(r"\.(h264|hevc|prores)\.(mp4|mov)$", r".\2", dst)
    os.replace(dst, final)
    return final


def run_job(job: Job):
    try:
        acquire_slot(job)
    except Cancelled:
        job.state, job.stage = "cancelled", "Cancelled"
        return
    try:
        job.state, job.stage = "running", "Checking the download"
        _run(job)
        job.state, job.stage, job.progress = "done", "Done", 1.0
        add_history({**job.to_dict(), "finished": time.time()})
    except Cancelled:
        job.state, job.stage = "cancelled", "Cancelled"
        cleanup_partial(job)
    except Exception as e:  # noqa: BLE001
        log(traceback.format_exc())
        job.state, job.stage = "failed", "Couldn't download"
        job.error = friendly_error(str(e))
        job.error_code = error_code(str(e))
        cleanup_partial(job)
    finally:
        release_slot()


def error_code(msg: str) -> str | None:
    low = msg.lower()
    if "cookies database" in low and browser_blocked(prefs.get("browser_cookies") or ""):
        return "permission"
    if "sign in to confirm" in low or "not a bot" in low or "login required" in low or "age-restricted" in low:
        return "signin"
    if "is live" in low or "live event" in low:
        return "live"
    return None


def cleanup_partial(job: "Job"):
    """Remove fragments, thumbnails and temp files this job created."""
    folder, vid = job.req.get("_folder"), job.req.get("_vid")
    if not folder or not vid:
        return
    for p in glob.glob(os.path.join(glob.escape(folder), f"*[[]{glob.escape(vid)}[]]*")):
        try:
            if os.path.getmtime(p) >= job.created - 1 and p != job.file:
                os.remove(p)
        except OSError:
            pass


def friendly_error(msg: str) -> str:
    msg = re.sub(r"\x1b\[[0-9;]*m", "", msg).replace("ERROR: ", "")
    low = msg.lower()
    b = prefs.get("browser_cookies") or ""
    if b and "cookies database" in low and browser_blocked(b):
        return PERMISSION_MSG.format(name=b.title())
    if "private video" in low:
        return "This video is private."
    if "sign in to confirm" in low or "not a bot" in low:
        return ("YouTube wants to be sure a real person is behind this download. "
                "Sign in with your browser to fix it.")
    if "is live" in low or "live event" in low:
        return "This stream is live. Download it once it has ended."
    if "no space left" in low:
        return "Your disk is full. Pick a lower quality or free up space."
    if "unsupported url" in low:
        return "That link isn't supported."
    return msg.strip()[:500]


def _run(job: Job):
    folder = os.path.expanduser(job.req.get("folder") or prefs["folder"])
    os.makedirs(folder, exist_ok=True)
    job.req["_folder"] = folder
    url = job.url
    tags = None

    if job.req.get("mode") == "spotify" or "open.spotify.com/track" in url:
        job.stage = "Matching on YouTube"
        tags = spotify_lookup(url) or {}
        q = " ".join(x for x in (tags.get("artist"), tags.get("title")) if x)
        url = f"ytsearch1:{q} audio"
        job.kind, job.format = "audio", job.format if job.format in ("mp3", "aac", "wav") else "mp3"
        job.title = q or job.title
        job.thumbnail = tags.get("cover") or job.thumbnail

    if job.req.get("mode") == "instrumental":
        job.stage = "Finding the instrumental"
        info = extract(url)
        title = info.get("track") or info.get("title") or ""
        artist = info.get("artist") or info.get("uploader") or ""
        hit = find_instrumental(title, artist)
        if not hit:
            raise RuntimeError("Couldn't find an instrumental of this song on YouTube.")
        url = hit["url"]
        job.title = hit["title"]
        job.kind = "audio"
        if job.format not in ("mp3", "aac", "wav"):
            job.format = prefs["audio_format"]

    fmt, extra = format_selector(job)
    outtmpl = os.path.join(folder, "%(title).180B [%(id)s].%(ext)s")

    def hook(d):
        vid = (d.get("info_dict") or {}).get("id")
        if vid:
            job.req["_vid"] = vid
        if job.cancel_flag.is_set():
            raise Cancelled()
        if d["status"] == "downloading":
            job.stage = "Downloading"
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            if total:
                job.progress = min(0.999, d.get("downloaded_bytes", 0) / total)
            elif d.get("fragment_count"):
                job.progress = min(0.999, (d.get("fragment_index") or 0) / d["fragment_count"])
            job.speed, job.eta = d.get("speed"), d.get("eta")
        elif d["status"] == "finished":
            job.stage = "Processing"

    def pp_hook(d):
        if job.cancel_flag.is_set():
            raise Cancelled()
        if d["status"] == "started":
            job.state = "converting"
            job.stage = {"FFmpegExtractAudio": "Converting audio",
                         "FFmpegMerger": "Joining video and sound",
                         "EmbedThumbnail": "Adding cover art"}.get(d.get("postprocessor"), "Processing")

    pps = []
    is_section = job.req.get("start") is not None or job.req.get("end") is not None
    want_thumb = prefs.get("embed_thumbnail", True)
    want_subs = prefs.get("embed_subs", False) and job.kind == "video"
    if job.kind == "audio":
        codec = {"mp3": "mp3", "aac": "m4a", "wav": "wav"}[job.format]
        pps.append({"key": "FFmpegExtractAudio", "preferredcodec": codec,
                    "preferredquality": "320" if codec == "mp3" else "0"})
    if want_subs:
        pps.append({"key": "FFmpegEmbedSubtitle", "already_have_subtitle": False})
    if prefs.get("embed_metadata", True):
        pps.append({"key": "FFmpegMetadata", "add_metadata": True, "add_chapters": not is_section})
    if want_thumb and job.format != "wav":
        pps.append({"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"})
        if job.kind == "audio":
            pps.append({"key": "EmbedThumbnail", "already_have_thumbnail": False})

    opts = base_opts({
        "format": fmt,
        "outtmpl": outtmpl,
        "progress_hooks": [hook],
        "postprocessor_hooks": [pp_hook],
        "postprocessors": pps,
        "writethumbnail": want_thumb and job.format != "wav",
        "writesubtitles": want_subs,
        "subtitleslangs": ["en.*", "en"] if want_subs else [],
        "noplaylist": True,
        "windowsfilenames": IS_WIN,
        **extra,
    })
    start, end = job.req.get("start"), job.req.get("end")
    if start is not None or end is not None:
        opts["download_ranges"] = download_range_func(None, [(float(start or 0), float(end or 1e9))])
        opts["force_keyframes_at_cuts"] = True
        outtmpl = os.path.join(folder, "%(title).160B [%(id)s] %(section_start)d-%(section_end)ds.%(ext)s")
        opts["outtmpl"] = outtmpl

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        if info.get("_type") == "playlist" and info.get("entries"):
            info = info["entries"][0]
        if tags is None:
            job.title = info.get("title") or job.title
            job.thumbnail = job.thumbnail or info.get("thumbnail")
        dur = info.get("duration") or 0
        if start is not None or end is not None:
            dur = float(end or dur) - float(start or 0)
        job.req["_duration"] = dur
        reqd = info.get("requested_downloads") or [{}]
        path = reqd[-1].get("filepath") or ydl.prepare_filename(info)

    if job.kind == "video" and job.format in ("h264", "hevc", "prores"):
        path = convert(job, path)
    if job.kind == "video" and want_thumb:
        embed_cover(path, strip_chapters=is_section)
    elif is_section:
        strip_timing_tracks(path)

    if tags and FFMPEG and path.endswith(".mp3"):
        tagged = path + ".tag.mp3"
        subprocess.run([FFMPEG, "-y", "-v", "error", "-i", path, "-map", "0", "-c", "copy",
                        "-metadata", f"title={tags.get('title') or ''}",
                        "-metadata", f"artist={tags.get('artist') or ''}", tagged], check=False)
        if os.path.exists(tagged):
            os.replace(tagged, path)
    job.file = path


def strip_timing_tracks(path: str):
    """Remove chapter and data tracks that still span the full original video.
    Players take the longest track as the file's length, so a leftover chapter
    track makes a short section play on as black frames."""
    if not FFMPEG or not path.endswith((".mp4", ".mov", ".m4v", ".m4a")):
        return
    root, ext = os.path.splitext(path)
    out = root + ".trim" + ext
    r = subprocess.run([FFMPEG, "-y", "-v", "error", "-i", path, "-map", "0", "-map", "-0:d",
                        "-map_chapters", "-1", "-c", "copy", out], capture_output=True)
    if r.returncode == 0 and os.path.exists(out):
        os.replace(out, path)
    elif os.path.exists(out):
        os.remove(out)


def embed_cover(path: str, strip_chapters: bool = False):
    """Attach the downloaded thumbnail as cover art (shown by Finder and players)."""
    root = os.path.splitext(path)[0]
    thumb = next((root + e for e in (".jpg", ".jpeg", ".png", ".webp") if os.path.exists(root + e)), None)
    if not thumb:
        return
    if not FFMPEG or not path.endswith((".mp4", ".mov", ".m4v")):
        os.remove(thumb)
        return
    out = root + ".cover" + os.path.splitext(path)[1]
    extra = ["-map", "-0:d", "-map_chapters", "-1"] if strip_chapters else []
    r = subprocess.run([FFMPEG, "-y", "-v", "error", "-i", path, "-i", thumb, "-map", "0", "-map", "1", *extra,
                        "-c", "copy", "-disposition:v:1", "attached_pic", out], capture_output=True)
    if r.returncode == 0 and os.path.exists(out):
        os.replace(out, path)
    elif os.path.exists(out):
        os.remove(out)
    os.remove(thumb)


def find_instrumental(title: str, artist: str) -> dict | None:
    q = f"ytsearch8:{artist} {title} instrumental".strip()
    with yt_dlp.YoutubeDL(base_opts({"extract_flat": True, "skip_download": True})) as ydl:
        res = ydl.extract_info(q, download=False)
    words = [w for w in re.findall(r"\w+", title.lower()) if len(w) > 2][:4]
    best, best_score = None, -1
    for e in res.get("entries") or []:
        t = (e.get("title") or "").lower()
        if not any(k in t for k in ("instrumental", "karaoke", "backing track", "no vocals")):
            continue
        score = sum(w in t for w in words) + (2 if "instrumental" in t else 0)
        if "cover" in t or "remix" in t:
            score -= 2
        if score > best_score:
            best, best_score = e, score
    if not best:
        return None
    return {"url": best.get("url") or f"https://www.youtube.com/watch?v={best['id']}",
            "title": best.get("title")}


def enqueue(req: dict) -> Job:
    for j in jobs.values():
        if (j.url == req["url"] and j.state in ("queued", "running", "converting")
                and j.req.get("start") == req.get("start") and j.req.get("end") == req.get("end")
                and j.req.get("mode") == req.get("mode")
                and j.kind == (req.get("kind") or prefs["kind"])
                and (req.get("format") in (None, j.format))):
            raise ValueError("Already downloading that one.")
    job = Job(req)
    jobs[job.id] = job
    job.future = executor.submit(run_job, job)
    return job


# --------------------------------------------------------------------------- bulk

URL_RE = re.compile(r"(https?://[^\s,;\"'<>]+|(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+/[^\s,;\"'<>]*)", re.I)


def parse_links(text: str) -> tuple[list[str], list[str]]:
    links, skipped = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        found = URL_RE.findall(line)
        if not found:
            skipped.append(line)
        for u in found:
            u = u.rstrip(").]")
            if not u.startswith("http"):
                u = "https://" + u
            if u not in links:
                links.append(u)
    return links, skipped


def expand(links: list[str], limit=500) -> list[dict]:
    out = []

    def one(u):
        try:
            info = extract(u, flat=True)
        except Exception as e:  # noqa: BLE001
            return [{"url": u, "title": u, "error": friendly_error(str(e))}]
        if info.get("_type") == "playlist":
            items = []
            for e in info.get("entries") or []:
                if not e:
                    continue
                url = e.get("url") or e.get("webpage_url")
                if url and not url.startswith("http") and e.get("ie_key") == "Youtube":
                    url = f"https://www.youtube.com/watch?v={e['id']}"
                items.append({"url": url, "title": e.get("title") or url,
                              "duration": e.get("duration"),
                              "thumbnail": (e.get("thumbnails") or [{}])[-1].get("url"),
                              "playlist": info.get("title")})
            return items
        s = summarize(info)
        return [{"url": s["url"] or u, "title": s["title"], "duration": s["duration"],
                 "thumbnail": s["thumbnail"]}]

    with cf.ThreadPoolExecutor(6) as pool:
        for items in pool.map(one, links):
            out.extend(items)
            if len(out) >= limit:
                break
    downloaded = {h["url"] for h in history if h.get("state") == "done"}
    for it in out[:limit]:
        it["downloaded"] = it.get("url") in downloaded
    return out[:limit]


# --------------------------------------------------------------------------- transcript

def transcript(url: str, folder: str) -> str:
    """Save the site's captions (manual first, then automatic) as plain text."""
    info = extract(url)
    subs = info.get("subtitles") or {}
    auto = info.get("automatic_captions") or {}
    track = None
    for pool in (subs, auto):
        for lang in ("en", "en-US", "en-GB", "en-orig"):
            if lang in pool:
                track = pool[lang]
                break
        if not track and pool:
            track = next(iter(pool.values()))
        if track:
            break
    if not track:
        raise RuntimeError("This video has no captions to save.")
    vtt = next((t for t in track if t.get("ext") == "vtt"), track[0])
    raw = urllib.request.urlopen(vtt["url"], timeout=30).read().decode("utf-8", "replace")
    lines, last = [], None
    for ln in raw.splitlines():
        if "-->" in ln or ln.startswith(("WEBVTT", "Kind:", "Language:", "NOTE")) or not ln.strip():
            continue
        clean = html.unescape(re.sub(r"<[^>]+>", "", ln)).strip()
        if clean and clean != last:
            lines.append(clean)
            last = clean
    os.makedirs(folder, exist_ok=True)
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "-", info.get("title") or info.get("id")).strip(" .")[:180]
    path = os.path.join(folder, f"{safe} [{info.get('id')}].txt")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    add_history({"id": uuid.uuid4().hex[:12], "url": url, "title": info.get("title"),
                 "thumbnail": info.get("thumbnail"), "kind": "transcript", "format": "txt",
                 "state": "done", "file": path, "created": time.time(), "finished": time.time()})
    return path


# --------------------------------------------------------------------------- section editor

FRAMES_DIR = os.path.join(CACHE, "frames")
_previews: dict[str, dict] = {}


def preview(url: str, max_height: int = 0) -> dict:
    """A progressive stream AVPlayer can play, plus a size estimate for the
    format Dwn would actually download."""
    info = extract_cached(url)
    fmts = info.get("formats") or []
    prog = [f for f in fmts
            if f.get("vcodec") not in (None, "none") and f.get("acodec") not in (None, "none")
            and f.get("protocol", "").startswith("http")]
    prog.sort(key=lambda f: (f.get("ext") == "mp4", f.get("height") or 0))
    if not prog:
        raise RuntimeError("Preview unavailable")
    stream = prog[-1]
    _previews[url] = {"stream": stream["url"], "headers": stream.get("http_headers") or {}}

    dur = info.get("duration") or 0
    def rate(f):  # bytes per second
        size = f.get("filesize") or f.get("filesize_approx")
        if size and dur:
            return size / dur
        return (f.get("tbr") or 0) * 1000 / 8

    video = [f for f in fmts if f.get("vcodec") not in (None, "none") and f.get("protocol", "").startswith(("http", "m3u8"))
             and (not max_height or (f.get("height") or 0) <= max_height)]
    audio = [f for f in fmts if f.get("vcodec") in (None, "none") and f.get("acodec") not in (None, "none")]
    best_v = max(video, key=lambda f: ((f.get("height") or 0), f.get("tbr") or 0), default=None)
    best_a = max(audio, key=lambda f: f.get("abr") or f.get("tbr") or 0, default=None)
    v_rate = rate(best_v) if best_v else 0
    a_rate = rate(best_a) if best_a and best_v and best_v.get("acodec") in (None, "none") else 0
    return {
        "stream": stream["url"], "headers": stream.get("http_headers") or {},
        "height": (best_v or {}).get("height"),
        "vcodec": (best_v or {}).get("vcodec"),
        "video_bps": v_rate, "audio_bps": a_rate or (rate(best_a) if best_a else 0),
        **summarize(info),
    }


def _safe(fn, *a):
    try:
        fn(*a)
    except Exception:  # noqa: BLE001
        log(traceback.format_exc())


SB_DIR = os.path.join(CACHE, "storyboards")
_sb_locks: dict[str, threading.Lock] = {}


def storyboard(url: str) -> dict:
    """YouTube's storyboard sprite sheets: grids of small frames covering the
    whole video. One small JPEG holds dozens of moments, so the filmstrip can
    show at once. Returns two levels (small for the strip, large for cards)."""
    import hashlib
    info = extract_cached(url)
    boards = [f for f in info.get("formats") or [] if f.get("format_note") == "storyboard" and f.get("fragments")]
    if not boards:
        return {"levels": []}
    boards.sort(key=lambda f: f.get("width") or 0)
    small = min(boards, key=lambda f: abs((f.get("width") or 0) - 160))
    large = boards[-1]
    picks = [small] if large is small or len(large["fragments"]) > 40 else [small, large]
    key = hashlib.sha1(url.encode()).hexdigest()[:16]
    folder = os.path.join(SB_DIR, key)
    os.makedirs(folder, exist_ok=True)
    lock = _sb_locks.setdefault(key, threading.Lock())

    def fetch(job):
        fid, i, frag = job
        out = os.path.join(folder, f"{fid}_{i}.jpg")
        if not (os.path.exists(out) and os.path.getsize(out) > 0):
            req = urllib.request.Request(frag["url"], headers={"User-Agent": "Mozilla/5.0"})
            data = urllib.request.urlopen(req, timeout=15).read()
            with open(out + ".tmp", "wb") as f:
                f.write(data)
            os.replace(out + ".tmp", out)
        return out

    levels = []
    with lock, cf.ThreadPoolExecutor(8) as pool:
        for b in picks:
            jobs = [(b["format_id"], i, fr) for i, fr in enumerate(b["fragments"])]
            paths = list(pool.map(fetch, jobs))
            sheets, t = [], 0.0
            for path, fr in zip(paths, b["fragments"]):
                d = float(fr.get("duration") or 0)
                sheets.append({"path": path, "start": t, "duration": d})
                t += d
            fps = b.get("fps") or 0
            levels.append({"width": b.get("width"), "height": b.get("height"), "rows": b.get("rows"),
                           "columns": b.get("columns"), "interval": (1 / fps) if fps else None, "sheets": sheets})
    return {"levels": levels}


def frames(url: str, times: list[float], width: int) -> dict:
    """Grab frames at the given times from the preview stream with ffmpeg.
    Returns {time: path}; frames are cached on disk."""
    import hashlib
    if not FFMPEG:
        raise RuntimeError("ffmpeg is missing, so frames can't be shown.")
    p = _previews.get(url) or {}
    if not p.get("stream"):
        preview(url)
        p = _previews[url]
    folder = os.path.join(FRAMES_DIR, hashlib.sha1(url.encode()).hexdigest()[:16])
    os.makedirs(folder, exist_ok=True)
    headers = "".join(f"{k}: {v}\r\n" for k, v in (p.get("headers") or {}).items())

    def grab(t: float):
        out = os.path.join(folder, f"{t:.1f}_{width}.jpg")
        if os.path.exists(out) and os.path.getsize(out) > 0:
            return t, out
        cmd = [FFMPEG, "-v", "error", "-y"]
        if width <= 200:
            cmd += ["-noaccurate_seek"]   # filmstrip tiles don't need frame-exact seeks
        cmd += ["-ss", f"{max(0, t):.2f}"]
        if headers:
            cmd += ["-headers", headers]
        cmd += ["-i", p["stream"], "-frames:v", "1", "-vf", f"scale={width}:-2", "-q:v", "5", out]
        try:
            subprocess.run(cmd, capture_output=True, timeout=25)
        except subprocess.TimeoutExpired:
            return t, None
        return t, out if os.path.exists(out) else None

    result = {}
    with cf.ThreadPoolExecutor(10) as pool:
        for t, path in pool.map(grab, times[:80]):
            if path:
                result[f"{t:.1f}"] = path
    return result


# --------------------------------------------------------------------------- sign-in

BROWSER_DIRS_MAC = {
    "chrome": "~/Library/Application Support/Google/Chrome",
    "brave": "~/Library/Application Support/BraveSoftware/Brave-Browser",
    "edge": "~/Library/Application Support/Microsoft Edge",
    "firefox": "~/Library/Application Support/Firefox",
}


def browser_blocked(browser: str) -> bool:
    """True when the browser's data folder exists but macOS won't let Dwn read
    it. yt-dlp reports that as "could not find", which is misleading."""
    if not IS_MAC:
        return False
    d = os.path.expanduser(BROWSER_DIRS_MAC.get(browser, ""))
    if not d or not os.path.isdir(d):
        return False
    try:
        os.listdir(d)
        return False
    except PermissionError:
        return True


PERMISSION_MSG = ("macOS is blocking Dwn from reading {name}'s data. Give Dwn Full Disk Access in "
                  "System Settings > Privacy & Security, then try again.")


def test_browser_login(browser: str) -> dict:
    """Read the browser's cookies (macOS may ask for the Keychain password)
    and report whether it holds a YouTube login."""
    from yt_dlp.cookies import extract_cookies_from_browser
    if browser_blocked(browser):
        return {"ok": False, "reason": "permission", "message": PERMISSION_MSG.format(name=browser.title())}
    try:
        jar = extract_cookies_from_browser(browser)
    except Exception as e:  # noqa: BLE001
        msg = str(e)
        if IS_WIN and ("dpapi" in msg.lower() or "app-bound" in msg.lower() or "decrypt" in msg.lower()):
            return {"ok": False, "reason": "locked",
                    "message": f"{browser.title()} locks its logins on Windows. Close it and try again, or use Firefox."}
        if "keychain" in msg.lower() or "password" in msg.lower():
            return {"ok": False, "reason": "keychain",
                    "message": "Your Mac didn't allow it. Try again, and choose Always Allow."}
        if "operation not permitted" in msg.lower() or browser_blocked(browser):
            return {"ok": False, "reason": "permission", "message": PERMISSION_MSG.format(name=browser.title())}
        if "could not copy" in msg.lower() or "being used by another process" in msg.lower():
            return {"ok": False, "reason": "locked",
                    "message": f"Close {browser.title()} completely, then try again."}
        if "could not find" in msg.lower() or "not find" in msg.lower():
            return {"ok": False, "reason": "missing", "message": f"Couldn't find {browser.title()} on this Mac."}
        return {"ok": False, "reason": "error", "message": friendly_error(msg)}
    yt = [c for c in jar if c.domain.endswith("youtube.com")]
    signed_in = any(c.name in ("SAPISID", "__Secure-3PAPISID", "LOGIN_INFO") for c in yt)
    return {"ok": True, "signed_in": signed_in, "cookies": len(yt)}


# --------------------------------------------------------------------------- update

def update_ytdlp() -> dict:
    meta = json.load(urllib.request.urlopen("https://pypi.org/pypi/yt-dlp/json", timeout=20))
    latest = meta["info"]["version"]
    current = yt_dlp.version.__version__
    norm = lambda v: tuple(int(x) for x in re.findall(r"\d+", v))  # noqa: E731
    if norm(latest) <= norm(current):
        return {"updated": False, "version": current}
    wheel = next(f for f in meta["urls"] if f["packagetype"] == "bdist_wheel")
    os.makedirs(UPDATES, exist_ok=True)
    dst = os.path.join(UPDATES, wheel["filename"])
    data = urllib.request.urlopen(wheel["url"], timeout=120).read()
    import hashlib
    if hashlib.sha256(data).hexdigest() != wheel["digests"]["sha256"]:
        raise RuntimeError("The update didn't download intact. Try again.")
    with open(dst + ".tmp", "wb") as f:
        f.write(data)
    os.replace(dst + ".tmp", dst)
    for old in glob.glob(os.path.join(UPDATES, "yt_dlp-*.whl")):
        if old != dst:
            os.remove(old)
    return {"updated": True, "version": latest, "restart": True}


# --------------------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code: int, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def _auth(self) -> bool:
        if TOKEN and self.headers.get("X-Dwn-Token") != TOKEN:
            self._send(403, {"error": "forbidden"})
            return False
        return True

    def do_GET(self):
        if not self._auth():
            return
        self._route("GET", {})

    def do_POST(self):
        if not self._auth():
            return
        try:
            body = self._body()
        except Exception:
            return self._send(400, {"error": "Bad JSON"})
        self._route("POST", body)

    def do_PUT(self):
        self.do_POST()

    def _route(self, method, body):
        path = urllib.parse.urlparse(self.path).path.rstrip("/")
        try:
            res = self._dispatch(method, path, body)
            self._send(200, res)
        except ValueError as e:
            self._send(409, {"error": str(e)})
        except KeyError as e:
            self._send(404, {"error": f"Not found: {e}"})
        except Exception as e:  # noqa: BLE001
            log(traceback.format_exc())
            self._send(500, {"error": friendly_error(str(e))})

    def _dispatch(self, method, path, b):
        if path == "/health":
            rt = js_runtime()
            return {"engine": ENGINE_VERSION, "ytdlp": yt_dlp.version.__version__,
                    "ffmpeg": FFMPEG, "js_runtime": rt[0] if rt else None,
                    "pid": os.getpid()}
        if path == "/prefs":
            if method == "POST":
                for k, v in b.items():
                    if k in DEFAULT_PREFS:
                        prefs[k] = v
                save_prefs()
                with slot_cv:
                    slot_cv.notify_all()
            return prefs
        if path == "/info":
            url = b["url"]
            if "open.spotify.com" in url:
                t = spotify_lookup(url) or {}
                return {"url": url, "title": t.get("title"), "uploader": t.get("artist"),
                        "thumbnail": t.get("cover"), "site": "Spotify", "is_playlist": False,
                        "duration": None, "chapters": [], "heatmap": []}
            info = extract_cached(url)
            if info.get("_type") != "playlist" and info.get("formats"):
                # Warm the section editor in the background: storyboard sprites.
                threading.Thread(target=lambda: _safe(storyboard, url), daemon=True).start()
            return summarize(info)
        if path == "/preview":
            return preview(b["url"], int(b.get("max_height") or prefs.get("max_height") or 0))
        if path == "/storyboard":
            return storyboard(b["url"])
        if path == "/frames":
            return {"frames": frames(b["url"], [float(t) for t in b.get("times") or []], int(b.get("width") or 192))}
        if path == "/download":
            return enqueue(b).to_dict()
        if path == "/jobs":
            return [j.to_dict() for j in sorted(jobs.values(), key=lambda j: j.created)]
        m = re.fullmatch(r"/jobs/(\w+)/(cancel|retry|dismiss)", path)
        if m:
            job = jobs[m.group(1)]
            if m.group(2) == "cancel":
                job.cancel_flag.set()
                if job.state == "queued":
                    job.state, job.stage = "cancelled", "Cancelled"
                return job.to_dict()
            if m.group(2) == "dismiss":
                jobs.pop(job.id, None)
                return {"ok": True}
            jobs.pop(job.id, None)
            req = {k: v for k, v in job.req.items() if not k.startswith("_")}
            return enqueue(req).to_dict()
        if path == "/jobs/cancel-all":
            for j in jobs.values():
                if j.state in ("queued", "running", "converting"):
                    j.cancel_flag.set()
                    if j.state == "queued":
                        j.state, j.stage = "cancelled", "Cancelled"
            return {"ok": True}
        if path == "/history":
            q = (b.get("query") or "").lower() if method == "POST" else ""
            items = [h for h in history if not q or q in (h.get("title") or "").lower()]
            for h in items:
                h["exists"] = bool(h.get("file")) and os.path.exists(h["file"])
            return items[:1000]
        if path == "/history/forget":
            ids = set(b.get("ids") or [])
            with lock:
                history[:] = [h for h in history if h.get("id") not in ids]
                save_json(HISTORY_PATH, history)
            return {"ok": True}
        if path == "/bulk/parse":
            links, skipped = parse_links(b.get("text", ""))
            return {"links": links, "skipped": skipped}
        if path == "/bulk/expand":
            links, skipped = parse_links(b.get("text", ""))
            return {"items": expand(links, int(b.get("limit") or 500)), "skipped": skipped}
        if path == "/bulk/start":
            batch = uuid.uuid4().hex[:8]
            queued, errors = [], []
            for it in b.get("items") or []:
                try:
                    queued.append(enqueue({**{k: v for k, v in b.items() if k != "items"},
                                           **it, "batch": batch}).to_dict())
                except ValueError as e:
                    errors.append({"url": it.get("url"), "error": str(e)})
            return {"batch": batch, "queued": queued, "errors": errors}
        if path == "/transcript":
            folder = os.path.expanduser(b.get("folder") or prefs["folder"])
            return {"file": transcript(b["url"], folder)}
        if path == "/search":
            q = b["query"]
            with yt_dlp.YoutubeDL(base_opts({"extract_flat": True})) as ydl:
                res = ydl.extract_info(f"ytsearch{int(b.get('n', 8))}:{q}", download=False)
            return [{"url": e.get("url"), "title": e.get("title"), "duration": e.get("duration"),
                     "uploader": e.get("channel") or e.get("uploader"),
                     "thumbnail": (e.get("thumbnails") or [{}])[-1].get("url")}
                    for e in res.get("entries") or []]
        if path == "/cookies/test":
            return test_browser_login(b.get("browser") or prefs.get("browser_cookies") or "chrome")
        if path == "/update-ytdlp":
            return update_ytdlp()
        raise KeyError(path)


def watch_stdin():
    """Exit when the parent app goes away (its end of our stdin closes)."""
    try:
        while sys.stdin.read(1):
            pass
    except Exception:
        pass
    os._exit(0)


def main():
    port = int(os.environ.get("DWN_PORT") or 0)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    if os.environ.get("DWN_WATCH_STDIN", "1") == "1":
        threading.Thread(target=watch_stdin, daemon=True).start()
    print(f"DWN_ENGINE_READY {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
