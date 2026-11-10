// Updates from GitHub Releases.
// Packaged Windows builds use electron-updater (reads latest.yml from the
// latest release, downloads the installer, verifies its SHA-512, installs on
// restart). In development it only checks the GitHub API so the UI can be tried.
const { app } = require('electron');
const settings = require('./settings');

const REPO = 'YuvrajxGarg/dwn';
const SIX_HOURS = 3 * 3600 * 1000; // check every 3 hours

let s = { phase: 'idle', version: null, notes: '', progress: 0, error: null, checkedAt: null, page: null };
let hooks = { onChange() {}, notify() {} };
let au = null;
let installWhenReady = false;

function set(patch) {
  s = { ...s, ...patch };
  hooks.onChange(state());
}

function state() {
  return { ...s, current: app.getVersion(), repo: REPO, autoCheck: settings.get('autoCheckUpdates'),
    canInstall: !!au };
}

function newer(a, b) {
  const pa = String(a).replace(/^v/, '').split(/\D+/).map(Number);
  const pb = String(b).replace(/^v/, '').split(/\D+/).map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0; const y = pb[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
}

function notifyOnce(version) {
  if (settings.get('notifiedVersion') === version) return;
  settings.set({ notifiedVersion: version });
  hooks.notify(`Dwn ${version} is available`, 'Click to see what\'s new and update.');
}

function notesText(n) {
  if (!n) return '';
  if (Array.isArray(n)) return n.map((x) => x.note || '').join('\n\n');
  return String(n).replace(/<[^>]+>/g, '').trim();
}

async function checkGitHub(manual) {
  set({ phase: 'checking', error: null });
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': `Dwn/${app.getVersion()}` },
    });
    if (r.status === 404) throw new Error('No releases have been published yet.');
    if (!r.ok) throw new Error('Couldn\'t reach the update server. Check your connection.');
    const j = await r.json();
    const v = String(j.tag_name || '').replace(/^v/i, '');
    if (newer(v, app.getVersion())) {
      set({ phase: 'available', version: v, notes: j.body || '', page: j.html_url, checkedAt: Date.now() });
      notifyOnce(v);
    } else {
      set({ phase: 'upToDate', version: v, checkedAt: Date.now() });
    }
  } catch (e) {
    set({ phase: manual ? 'failed' : 'idle', error: e.message });
  }
}

function init(h) {
  hooks = { ...hooks, ...h };
  if (app.isPackaged && process.platform === 'win32') {
    try {
      ({ autoUpdater: au } = require('electron-updater'));
      // Background updates: download the newest version quietly and install it on quit.
      au.autoDownload = !!settings.get('autoInstallUpdates');
      au.autoInstallOnAppQuit = true;
      au.allowDowngrade = false;
      au.on('checking-for-update', () => set({ phase: 'checking', error: null }));
      au.on('update-available', (info) => {
        set({ phase: 'available', version: info.version, notes: notesText(info.releaseNotes),
          page: `https://github.com/${REPO}/releases/tag/v${info.version}`, checkedAt: Date.now() });
        notifyOnce(info.version);
      });
      au.on('update-not-available', (info) => set({ phase: 'upToDate', version: info.version, checkedAt: Date.now() }));
      au.on('download-progress', (p) => set({ phase: 'downloading', progress: (p.percent || 0) / 100 }));
      au.on('update-downloaded', (info) => {
        set({ phase: 'ready', version: info.version, progress: 1 });
        if (installWhenReady) { installWhenReady = false; setImmediate(() => au.quitAndInstall(false, true)); }
      });
      au.on('error', (e) => set({ phase: 'failed', error: friendly(e) }));
    } catch {
      au = null;
    }
  }
  setTimeout(() => { if (settings.get('autoCheckUpdates')) check(false); }, 8000);
  setInterval(() => { if (settings.get('autoCheckUpdates')) check(false); }, SIX_HOURS);
}

function friendly(e) {
  const m = String((e && e.message) || e || '');
  if (/net::|ENOTFOUND|ETIMEDOUT|ECONNRESET/.test(m)) return 'Couldn\'t reach the update server. Check your connection.';
  if (/sha512|checksum/i.test(m)) return 'The update didn\'t download intact. Try again.';
  if (/404|Cannot find latest/i.test(m)) return 'The update server didn\'t have the update. Try again later.';
  return m.split('\n')[0].slice(0, 200) || 'Couldn\'t update.';
}

async function check(manual) {
  if (s.phase === 'downloading') return state();
  if (au) {
    au.autoDownload = !!settings.get('autoInstallUpdates');
    try { await au.checkForUpdates(); } catch (e) { set({ phase: manual ? 'failed' : 'idle', error: friendly(e) }); }
  } else {
    await checkGitHub(manual);
  }
  return state();
}

async function install() {
  if (!au) {
    // Development or unsupported: open the release page instead.
    const { shell } = require('electron');
    shell.openExternal(s.page || `https://github.com/${REPO}/releases/latest`);
    return state();
  }
  // Ask GitHub again first: if a newer release came out since the last check,
  // install that one directly instead of anything in between.
  const readyVersion = s.phase === 'ready' ? s.version : null;
  let latest = null;
  try {
    au.autoDownload = false;
    const r = await au.checkForUpdates();
    latest = r && r.updateInfo && r.updateInfo.version;
  } catch (e) {
    if (!readyVersion) { set({ phase: 'failed', error: friendly(e) }); return state(); }
  } finally {
    au.autoDownload = !!settings.get('autoInstallUpdates');
  }
  if (readyVersion && (!latest || !newer(latest, readyVersion))) {
    setImmediate(() => au.quitAndInstall(false, true));
    return state();
  }
  installWhenReady = true;
  set({ phase: 'downloading', progress: 0 });
  try { await au.downloadUpdate(); } catch (e) { installWhenReady = false; set({ phase: 'failed', error: friendly(e) }); }
  return state();
}

module.exports = { init, check, install, state };
