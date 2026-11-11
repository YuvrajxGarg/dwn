"""Cloud drives for Dwn: browse Google Drive, Dropbox and friends, and copy
whole folders to and from this computer.

Built on rclone (https://rclone.org). The engine runs ``rclone rcd`` (its
remote-control server) on 127.0.0.1 with a random password and drives it over
HTTP. Accounts live in Dwn's own rclone.conf, so they never mix with an rclone
the user set up themselves.

Google Drive folders are copied file by file, the way they are stored, so they
never get split into the 2 GB zip parts the Drive website makes.
"""

from __future__ import annotations

import base64
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

IS_WIN = sys.platform.startswith("win")

# Services Dwn offers, in menu order. "shared" names the views each one has
# besides its own files: (view id, title, rclone connection-string option).
SERVICES = {
    "drive": {"name": "Google Drive", "shared": [("shared", "Shared with me", "shared_with_me")]},
    "dropbox": {"name": "Dropbox", "shared": [("shared", "Shared folders", "shared_folders"),
                                              ("shared_files", "Shared files", "shared_files")]},
    "onedrive": {"name": "OneDrive", "shared": []},
    "box": {"name": "Box", "shared": []},
    "pcloud": {"name": "pCloud", "shared": []},
}

MAX_RUNNING = 3          # transfers copying at the same time (each copies several files at once)

_ctx: dict = {}
_lock = threading.RLock()
_rcd: dict = {}          # proc, url, auth
_auth: dict = {}         # the one sign-in in progress
transfers: dict[str, dict] = {}


def setup(*, which, support: str, cache: str, log, prefs: dict):
    _ctx.update(which=which, support=support, cache=cache, log=log, prefs=prefs)
    _ctx["conf"] = os.path.join(support, "rclone.conf")
    _ctx["meta_path"] = os.path.join(support, "cloud.json")
    threading.Thread(target=_pump, daemon=True).start()


def _log(*a):
    _ctx["log"]("[cloud]", *a)


def rclone_path() -> str | None:
    return os.environ.get("DWN_RCLONE") or _ctx["which"]("rclone")


def _hidden() -> dict:
    """Keep rclone from flashing a console window on Windows."""
    if IS_WIN:
        return {"creationflags": 0x08000000}   # CREATE_NO_WINDOW
    return {}


# --------------------------------------------------------------------------- account labels

def _meta() -> dict:
    try:
        with open(_ctx["meta_path"]) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_meta(m: dict):
    tmp = _ctx["meta_path"] + ".tmp"
    with open(tmp, "w") as f:
        json.dump(m, f, indent=1)
    os.replace(tmp, _ctx["meta_path"])


# --------------------------------------------------------------------------- rclone rcd

def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _ensure_rcd():
    with _lock:
        p = _rcd.get("proc")
        if p and p.poll() is None:
            return
        exe = rclone_path()
        if not exe:
            raise ValueError("Cloud drives need rclone, which is missing from this copy of Dwn.")
        port, user, pw = _free_port(), "dwn", secrets.token_hex(16)
        cache = os.path.join(_ctx["cache"], "rclone")
        os.makedirs(cache, exist_ok=True)
        cmd = [exe, "rcd", f"--rc-addr=127.0.0.1:{port}", f"--rc-user={user}", f"--rc-pass={pw}",
               f"--config={_ctx['conf']}", f"--cache-dir={cache}",
               "--transfers=4", "--checkers=8", "--low-level-retries=10", "--retries=3",
               "--drive-acknowledge-abuse", "--log-level=NOTICE"]
        _log("starting", exe)
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=sys.stderr, **_hidden())
        _rcd.update(proc=proc, url=f"http://127.0.0.1:{port}/",
                    auth="Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode())
        for _ in range(100):
            if proc.poll() is not None:
                raise ValueError("rclone couldn't start. Its messages are in the engine log.")
            try:
                _call("rc/noop", {}, ensure=False, timeout=2)
                return
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(0.1)
        raise ValueError("rclone took too long to start.")


def shutdown():
    p = _rcd.get("proc")
    if p and p.poll() is None:
        p.terminate()
    a = _auth.get("proc")
    if a and a.poll() is None:
        a.terminate()


def _call(method: str, params: dict, ensure=True, timeout=600) -> dict:
    if ensure:
        _ensure_rcd()
    req = urllib.request.Request(_rcd["url"] + method, data=json.dumps(params).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": _rcd["auth"]})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get("error") or str(e)
        except Exception:
            msg = str(e)
        raise ValueError(friendly(msg)) from None


def friendly(msg: str) -> str:
    low = msg.lower()
    if "directory not found" in low or "object not found" in low:
        return "That isn't there anymore. Refresh and try again."
    if "invalid_grant" in low or ("token" in low and ("expired" in low or "revoked" in low)):
        return "This account was signed out. Remove it and add it again."
    if "ratelimitexceeded" in low or "userratelimitexceeded" in low or "rate limit" in low:
        return "Google is limiting how fast this account can download. Dwn will keep retrying; try again in a few minutes."
    if "quota" in low and "download" in low:
        return "Google's download limit for this file was reached. Try again in 24 hours, or make a copy of it in your own Drive."
    if ("insufficient" in low and "permission" in low) or ("403" in low and "forbidden" in low):
        return "You don't have access to that."
    if "context canceled" in low:
        return "Cancelled"
    if "no space left" in low:
        return "The disk is full."
    return msg.strip().split("\n")[0][:300]


# --------------------------------------------------------------------------- accounts

def accounts() -> list[dict]:
    if not rclone_path():
        return []
    remotes = _call("config/dump", {})
    meta = _meta()
    out = []
    for name, cfg in sorted(remotes.items()):
        t = cfg.get("type", "")
        if t not in SERVICES:
            continue
        m = meta.get(name, {})
        out.append({"name": name, "type": t, "service": SERVICES[t]["name"],
                    # Signed in through Dwn's own Google app, or rclone's shared (rate-limited) one.
                    "own_client": bool(cfg.get("client_id")),
                    "email": m.get("email"), "label": m.get("label") or m.get("email") or SERVICES[t]["name"],
                    "views": [{"id": "files", "title": "My Drive" if t == "drive" else "Files"}] +
                             [{"id": v, "title": title} for v, title, _ in SERVICES[t]["shared"]]})
    return out


def status() -> dict:
    exe = rclone_path()
    out = {"available": bool(exe), "services": [{"type": k, "name": v["name"]} for k, v in SERVICES.items()],
           "accounts": [], "connecting": _auth_state()}
    if exe:
        try:
            out["accounts"] = accounts()
            out["version"] = _call("core/version", {}).get("version")
        except ValueError as e:
            out["error"] = str(e)
    return out


# --------------------------------------------------------------------------- sign-in apps
#
# Google limits API calls per sign-in app ("client ID"). rclone's built-in one is
# shared by every rclone user, so it is often over quota (listings stall while
# rclone backs off) and Google is retiring it. Dwn uses its own when it has one:
# the user's, saved from the app, or one bundled with the build.

def _bundled_clients() -> dict:
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    for d in (getattr(sys, "_MEIPASS", here), here, os.path.dirname(os.path.abspath(__file__))):
        try:
            with open(os.path.join(d, "cloud_clients.json")) as f:
                return json.load(f)
        except Exception:
            continue
    return {}


def client_for(service: str) -> tuple[str, str] | None:
    env = {"id": os.environ["DWN_GOOGLE_CLIENT_ID"], "secret": os.environ.get("DWN_GOOGLE_CLIENT_SECRET", "")} \
        if service == "drive" and os.environ.get("DWN_GOOGLE_CLIENT_ID") else None
    c = _meta().get("_clients", {}).get(service) or env or _bundled_clients().get(service) or {}
    return (c["id"], c.get("secret", "")) if c.get("id") else None


def clients() -> dict:
    user = _meta().get("_clients", {})
    out = {}
    for svc in SERVICES:
        c = client_for(svc)
        out[svc] = {"id": c[0] if c else None, "mine": bool(user.get(svc, {}).get("id"))}
    return out


def set_client(service: str, cid: str, secret: str) -> dict:
    if service not in SERVICES:
        raise ValueError("Dwn doesn't support that service.")
    cid, secret = (cid or "").strip(), (secret or "").strip()
    if cid and service == "drive" and not cid.endswith(".apps.googleusercontent.com"):
        raise ValueError("That doesn't look like a Google client ID. It ends in .apps.googleusercontent.com.")
    meta = _meta()
    cl = meta.setdefault("_clients", {})
    if cid:
        cl[service] = {"id": cid, "secret": secret}
    else:
        cl.pop(service, None)
    _save_meta(meta)
    return clients()


def _auth_state() -> dict | None:
    if not _auth:
        return None
    return {k: _auth.get(k) for k in ("id", "type", "state", "url", "error", "account")}


def connect(service: str, replace: str | None = None) -> dict:
    """Start signing in: rclone opens a tiny local web server and gives us the
    link to the provider's sign-in page, which the app opens in the browser.
    With ``replace``, the new sign-in goes into that existing account."""
    if service not in SERVICES:
        raise ValueError("Dwn doesn't support that service.")
    exe = rclone_path()
    if not exe:
        raise ValueError("Cloud drives need rclone, which is missing from this copy of Dwn.")
    with _lock:
        old = _auth.get("proc")
        if old and old.poll() is None:
            old.terminate()
            try:
                old.wait(3)
            except Exception:
                pass
        _auth.clear()
        client = client_for(service)
        _auth.update(id=uuid.uuid4().hex[:8], type=service, state="starting", url=None, error=None, account=None,
                     client=client, replace=replace)
        cmd = [exe, "authorize", service] + (list(client) if client else []) + ["--auth-no-open-browser"]
        proc = subprocess.Popen(cmd,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace", **_hidden())
        _auth["proc"] = proc
        auth_id = _auth["id"]
    threading.Thread(target=_watch_auth, args=(auth_id, proc, service), daemon=True).start()
    # Wait briefly for the sign-in link so the app can open it right away.
    for _ in range(50):
        if _auth.get("url") or _auth.get("state") in ("failed", "done"):
            break
        time.sleep(0.1)
    return _auth_state()


def _watch_auth(auth_id: str, proc, service: str):
    out = []
    for line in proc.stdout:
        out.append(line)
        m = re.search(r"https?://127\.0\.0\.1:\d+/auth\?state=\S+", line)
        if m and _auth.get("id") == auth_id:
            _auth.update(url=m.group(0), state="waiting")
    proc.wait()
    if _auth.get("id") != auth_id:
        return
    text = "".join(out)
    token = _parse_token(text)
    if not token:
        if _auth.get("state") != "cancelled":
            err = next((l for l in reversed(out) if "error" in l.lower() or "failed" in l.lower()), "")
            _auth.update(state="failed", error=friendly(err) if err else "Sign-in didn't finish.")
            _log("authorize failed:", text[-2000:])
        return
    try:
        _auth["account"] = _create_account(service, token, _auth.get("client"), _auth.get("replace"))
        _auth["state"] = "done"
    except Exception as e:  # noqa: BLE001
        _auth.update(state="failed", error=str(e))


def _parse_token(text: str) -> str | None:
    m = re.search(r"--->\s*(.+?)\s*<---", text, re.S)
    if not m:
        return None
    blob = m.group(1).strip()
    if blob.startswith("{"):
        return blob
    # Newer rclone versions may hand back a base64 config blob instead.
    try:
        data = json.loads(base64.b64decode(blob + "=" * (-len(blob) % 4)))
        tok = data.get("token") if isinstance(data, dict) else None
        return tok if isinstance(tok, str) else (json.dumps(tok) if tok else None)
    except Exception:
        return None


def _create_account(service: str, token: str, client: tuple[str, str] | None = None,
                    replace: str | None = None) -> dict:
    existing = set(_call("config/listremotes", {}).get("remotes") or [])
    params = {"token": token}
    if client:
        params.update(client_id=client[0], client_secret=client[1])
    if replace and replace in existing:
        name = replace
        if not client:
            params.update(client_id="", client_secret="")
        _call("config/update", {"name": name, "parameters": params, "opt": {"nonInteractive": True, "obscure": True}})
    else:
        name, n = service, 2
        while name in existing:
            name, n = f"{service}{n}", n + 1
        if service == "drive":
            params["scope"] = "drive"
        _call("config/create", {"name": name, "type": service, "parameters": params,
                                "opt": {"nonInteractive": True, "obscure": True}})
    email = _whoami(service, token)
    meta = _meta()
    meta[name] = {"email": email or meta.get(name, {}).get("email")}
    _save_meta(meta)
    _log("connected", service, "as", name, "with Dwn's own sign-in app" if client else "with rclone's shared sign-in app")
    return next((a for a in accounts() if a["name"] == name), {"name": name, "type": service})


def _whoami(service: str, token: str) -> str | None:
    """The signed-in email, so two accounts of one service are easy to tell apart."""
    try:
        access = json.loads(token).get("access_token")
        if service == "drive":
            req = urllib.request.Request("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)",
                                         headers={"Authorization": f"Bearer {access}"})
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())["user"]["emailAddress"]
        if service == "dropbox":
            req = urllib.request.Request("https://api.dropboxapi.com/2/users/get_current_account", data=b"null",
                                         headers={"Authorization": f"Bearer {access}",
                                                  "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())["email"]
    except Exception as e:  # noqa: BLE001
        _log("couldn't read the account email:", e)
    return None


def cancel_connect():
    p = _auth.get("proc")
    _auth["state"] = "cancelled"
    if p and p.poll() is None:
        p.terminate()
    return {"ok": True}


def disconnect(name: str):
    _call("config/delete", {"name": name})
    meta = _meta()
    meta.pop(name, None)
    _save_meta(meta)
    return {"ok": True}


# --------------------------------------------------------------------------- browsing

def drive_link_id(link: str) -> tuple[str, bool]:
    """Folder or file ID from a Google Drive link. Returns (id, is_folder)."""
    link = link.strip()
    for pat, folder in ((r"/folders/([\w-]{10,})", True), (r"/file/d/([\w-]{10,})", False),
                        (r"/document/d/([\w-]{10,})", False), (r"/spreadsheets/d/([\w-]{10,})", False),
                        (r"/presentation/d/([\w-]{10,})", False)):
        m = re.search(pat, link)
        if m:
            return m.group(1), folder
    q = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
    if q.get("id"):
        return q["id"][0], True
    if re.fullmatch(r"[\w-]{20,}", link):
        return link, True
    raise ValueError("That doesn't look like a Google Drive folder link.")


def fs_for(account: str, view: str = "files", link: str | None = None) -> str:
    """The rclone remote for one view of an account, e.g. ``drive,shared_with_me:``."""
    if not re.fullmatch(r"[\w.-]+", account or ""):
        raise ValueError("Unknown account.")
    if view == "link":
        fid, folder = drive_link_id(link or "")
        if not folder:
            raise ValueError("That's a link to a single file. Paste it in the Download tab instead.")
        return f"{account},root_folder_id={fid}:"
    t = next((a["type"] for a in accounts() if a["name"] == account), None)
    if not t:
        raise ValueError("That account isn't connected anymore.")
    for vid, _, opt in SERVICES[t]["shared"]:
        if vid == view:
            return f"{account},{opt}:"
    return f"{account}:"


def list_dir(account: str, view: str, path: str, link: str | None = None) -> dict:
    fs = fs_for(account, view, link)
    path = path.strip("/")
    # Who shared what: Drive reports each shared item's owner in its metadata.
    want_owner = view == "shared" and not path and fs.startswith(account + ",shared_with_me")
    res = (_list_with_owners(fs) if want_owner else None) or _call("operations/list", {"fs": fs, "remote": path})
    items = []
    for e in res.get("list") or []:
        md = e.get("Metadata") or {}
        owner = md.get("owner")
        items.append({"name": e.get("Name"), "path": e.get("Path"), "is_dir": bool(e.get("IsDir")),
                      "size": e.get("Size") if (e.get("Size") or -1) >= 0 else None,
                      "modified": e.get("ModTime"), "mime": e.get("MimeType"), "id": e.get("ID"),
                      "owner": owner})
    items.sort(key=lambda i: (not i["is_dir"], (i["name"] or "").lower()))
    return {"fs": fs, "path": path, "items": items}


def _list_with_owners(fs: str) -> dict | None:
    """The top of "Shared with me" with each item's owner.

    Asked through rclone's server (operations/list with metadata), this never
    returns for some accounts, while the command-line tool lists the same thing
    in seconds. So it goes through the command line, and the caller falls back
    to a plain listing (no grouping by person) if that fails or is slow."""
    try:
        r = subprocess.run([rclone_path(), "lsjson", fs, "--metadata", f"--config={_ctx['conf']}",
                            "--low-level-retries=3"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=45, **_hidden())
        if r.returncode == 0:
            return {"list": json.loads(r.stdout or "[]")}
        _log("owner listing failed:", (r.stderr or "").strip()[-300:])
    except Exception as e:  # noqa: BLE001
        _log("owner listing failed:", e)
    return None


def about(account: str) -> dict:
    try:
        r = _call("operations/about", {"fs": fs_for(account)}, timeout=60)
        return {"total": r.get("total"), "used": r.get("used"), "free": r.get("free")}
    except Exception as e:  # noqa: BLE001  (storage use is a nice-to-have; never fail on it)
        _log("about failed:", e)
        return {}


def mkdir(account: str, view: str, path: str, link: str | None = None):
    _call("operations/mkdir", {"fs": fs_for(account, view, link), "remote": path.strip("/")})
    return {"ok": True}


def delete(account: str, view: str, items: list[dict], link: str | None = None):
    fs = fs_for(account, view, link)
    for it in items:
        p = (it.get("path") or "").strip("/")
        if not p:
            continue
        if it.get("is_dir"):
            _call("operations/purge", {"fs": fs, "remote": p})
        else:
            _call("operations/deletefile", {"fs": fs, "remote": p})
    return {"ok": True}


# --------------------------------------------------------------------------- transfers

def _unique(folder: str, name: str) -> str:
    """A name in folder that isn't taken yet: "Photos", then "Photos (2)"..."""
    base, ext = os.path.splitext(name)
    cand, n = name, 2
    while os.path.exists(os.path.join(folder, cand)):
        cand, n = f"{base} ({n}){ext}", n + 1
    return cand


def _new(**kw) -> dict:
    t = {"id": uuid.uuid4().hex[:12], "state": "queued", "bytes": 0, "total": None, "speed": None,
         "eta": None, "files": 0, "files_total": None, "error": None, "created": time.time(),
         "finished": None, "jobid": None, **kw}
    with _lock:
        transfers[t["id"]] = t
    return t


def download(account: str, view: str, items: list[dict], dest: str | None = None,
             link: str | None = None) -> list[dict]:
    fs = fs_for(account, view, link)
    dest = os.path.expanduser(dest or _ctx["prefs"]["folder"])
    os.makedirs(dest, exist_ok=True)
    out = []
    for it in items:
        path = (it.get("path") or "").strip("/")
        name = it.get("name") or os.path.basename(path) or "Download"
        if view == "link" and not path:
            name = it.get("name") or "Shared folder"
        local = _unique(dest, name.replace("/", "-"))
        out.append(_new(direction="down", account=account, name=name, is_dir=bool(it.get("is_dir")),
                        src_fs=fs, src=path, dst_fs=dest, dst=local, local=os.path.join(dest, local)))
    return out


def upload(account: str, view: str, folder: str, files: list[str], link: str | None = None) -> list[dict]:
    fs = fs_for(account, view, link)
    folder = folder.strip("/")
    out = []
    for f in files:
        f = os.path.abspath(os.path.expanduser(f))
        if not os.path.exists(f):
            continue
        name = os.path.basename(f.rstrip(os.sep))
        out.append(_new(direction="up", account=account, name=name, is_dir=os.path.isdir(f),
                        src_fs=os.path.dirname(f), src=name, dst_fs=fs,
                        dst=f"{folder}/{name}" if folder else name, local=f))
    return out


def _start(t: dict):
    if t["is_dir"]:
        src = t["src_fs"] + t["src"] if t["src_fs"].endswith(":") else os.path.join(t["src_fs"], t["src"])
        dst = t["dst_fs"] + t["dst"] if t["dst_fs"].endswith(":") else os.path.join(t["dst_fs"], t["dst"])
        r = _call("sync/copy", {"srcFs": src, "dstFs": dst, "createEmptySrcDirs": True, "_async": True})
    else:
        r = _call("operations/copyfile", {"srcFs": t["src_fs"], "srcRemote": t["src"],
                                          "dstFs": t["dst_fs"], "dstRemote": t["dst"], "_async": True})
    t.update(jobid=r["jobid"], state="running", started=time.time())


def _update(t: dict):
    jid = t["jobid"]
    try:
        st = _call("core/stats", {"group": f"job/{jid}"}, timeout=10)
        js = _call("job/status", {"jobid": jid}, timeout=10)
    except Exception as e:  # noqa: BLE001
        if not (_rcd.get("proc") and _rcd["proc"].poll() is None):
            t.update(state="failed", error="rclone stopped unexpectedly.", finished=time.time())
        else:
            _log("status failed:", e)
        return
    t["bytes"] = st.get("bytes") or 0
    t["total"] = st.get("totalBytes") or t.get("total")
    t["speed"] = st.get("speed")
    t["eta"] = st.get("eta")
    t["files"] = st.get("transfers") or 0
    t["files_total"] = st.get("totalTransfers") or None
    t["current"] = [x.get("name") for x in (st.get("transferring") or [])][:3]
    if js.get("finished"):
        t["finished"] = time.time()
        t["speed"] = t["eta"] = None
        t["current"] = []
        if t.get("cancel"):
            t["state"], t["error"] = "cancelled", None
        elif js.get("success") and not st.get("errors"):
            t["state"] = "done"
        elif js.get("success"):
            t["state"] = "done"
            t["error"] = f"{st['errors']} file(s) couldn't be copied: {friendly(st.get('lastError') or '')}"
        else:
            t["state"], t["error"] = "failed", friendly(js.get("error") or st.get("lastError") or "Failed")


def _pump():
    """Starts queued transfers when a slot is free and refreshes running ones."""
    while True:
        try:
            with _lock:
                items = list(transfers.values())
            running = [t for t in items if t["state"] == "running"]
            for t in running:
                _update(t)
            free = MAX_RUNNING - sum(1 for t in items if t["state"] == "running")
            for t in sorted((t for t in items if t["state"] == "queued"), key=lambda t: t["created"]):
                if free <= 0:
                    break
                try:
                    _start(t)
                    free -= 1
                except Exception as e:  # noqa: BLE001
                    t.update(state="failed", error=str(e), finished=time.time())
        except Exception as e:  # noqa: BLE001
            _log("pump:", e)
        time.sleep(0.7)


def public(t: dict) -> dict:
    return {k: t.get(k) for k in ("id", "direction", "account", "name", "is_dir", "state", "bytes", "total",
                                  "speed", "eta", "files", "files_total", "error", "created", "finished",
                                  "local", "current")}


def transfer_action(tid: str, action: str) -> dict:
    t = transfers[tid]
    if action == "cancel":
        t["cancel"] = True
        if t["state"] == "queued":
            t.update(state="cancelled", finished=time.time())
        elif t["state"] == "running" and t["jobid"]:
            try:
                _call("job/stop", {"jobid": t["jobid"]}, timeout=10)
            except ValueError:
                pass
        return public(t)
    if action == "dismiss":
        with _lock:
            transfers.pop(tid, None)
        return {"ok": True}
    if action == "retry":
        # rclone skips files that are already there, so a retry picks up where it stopped.
        t.update(state="queued", error=None, jobid=None, cancel=False, finished=None, bytes=0, speed=None, eta=None)
        return public(t)
    raise KeyError(action)


def clear_finished():
    with _lock:
        for tid in [k for k, t in transfers.items() if t["state"] in ("done", "cancelled")]:
            transfers.pop(tid, None)
    return {"ok": True}


# --------------------------------------------------------------------------- http

def dispatch(method: str, path: str, b: dict):
    if path == "/cloud/status":
        return status()
    if path == "/cloud/connect":
        return connect(b.get("service") or "drive", b.get("replace"))
    if path == "/cloud/clients":
        if method == "POST":
            return set_client(b.get("service") or "drive", b.get("id") or "", b.get("secret") or "")
        return clients()
    if path == "/cloud/connect/status":
        return _auth_state() or {}
    if path == "/cloud/connect/cancel":
        return cancel_connect()
    if path == "/cloud/disconnect":
        return disconnect(b["account"])
    if path == "/cloud/list":
        return list_dir(b["account"], b.get("view") or "files", b.get("path") or "", b.get("link"))
    if path == "/cloud/about":
        return about(b["account"])
    if path == "/cloud/mkdir":
        return mkdir(b["account"], b.get("view") or "files", b["path"], b.get("link"))
    if path == "/cloud/delete":
        return delete(b["account"], b.get("view") or "files", b.get("items") or [], b.get("link"))
    if path == "/cloud/download":
        return [public(t) for t in download(b["account"], b.get("view") or "files", b.get("items") or [],
                                            b.get("dest"), b.get("link"))]
    if path == "/cloud/upload":
        return [public(t) for t in upload(b["account"], b.get("view") or "files", b.get("path") or "",
                                          b.get("files") or [], b.get("link"))]
    if path == "/cloud/transfers":
        return [public(t) for t in sorted(transfers.values(), key=lambda t: t["created"])]
    if path == "/cloud/transfers/clear":
        return clear_finished()
    m = re.fullmatch(r"/cloud/transfers/(\w+)/(cancel|retry|dismiss)", path)
    if m:
        return transfer_action(m.group(1), m.group(2))
    raise KeyError(path)
