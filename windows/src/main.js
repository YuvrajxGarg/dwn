// Dwn for Windows: Electron shell around the same Python download engine the
// macOS app uses. The engine is a local HTTP server guarded by a per-launch
// token; every renderer call goes through main (see `api` below).
const {
  app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, shell, dialog,
  clipboard, Notification, screen, nativeImage,
} = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn } = require('child_process');
const settings = require('./settings');
const updater = require('./updater');

const IS_WIN = process.platform === 'win32';
const RES = app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', 'build');

// Keep Electron's own data in a subfolder so it never mixes with the engine's
// prefs and history (which live in the "Dwn" folder itself).
app.setPath('userData', path.join(app.getPath('appData'), 'Dwn', 'App'));
const SNAPSHOT = process.env.DWN_SNAPSHOT || '';

if (!app.requestSingleInstanceLock()) {
  app.quit();
  process.exit(0);
}

let mainWin = null;
let panelWin = null;
let tray = null;
let quitting = false;

// ---------------------------------------------------------------- engine

const engine = {
  proc: null,
  port: 0,
  token: crypto.randomBytes(24).toString('hex'),
  state: 'stopped', // stopped | starting | running | failed
  message: '',
  crashes: 0,
  stopping: false,
  logPath: path.join(app.getPath('logs'), 'engine.log'),

  command() {
    if (app.isPackaged) {
      const exe = path.join(process.resourcesPath, 'engine', IS_WIN ? 'dwn-engine.exe' : 'dwn-engine');
      return fs.existsSync(exe) ? [exe, []] : null;
    }
    // Development: run engine.py with the repo's virtualenv.
    const script = path.join(__dirname, '..', '..', 'engine', 'engine.py');
    const venv = path.join(__dirname, '..', '..', 'engine', '.venv');
    const py = IS_WIN ? path.join(venv, 'Scripts', 'python.exe') : path.join(venv, 'bin', 'python');
    return [fs.existsSync(py) ? py : (IS_WIN ? 'python' : 'python3'), [script]];
  },

  setState(state, message = '') {
    this.state = state;
    this.message = message;
    broadcast('engine', { state, message });
  },

  start() {
    if (this.proc) return;
    const cmd = this.command();
    if (!cmd) return this.setState('failed', 'The download engine is missing from this copy of Dwn. Reinstall Dwn.');
    this.stopping = false;
    this.setState('starting');
    fs.mkdirSync(path.dirname(this.logPath), { recursive: true });
    const log = fs.createWriteStream(this.logPath, { flags: 'w' });
    const env = { ...process.env, DWN_TOKEN: this.token, PYTHONUNBUFFERED: '1' };
    const p = spawn(cmd[0], cmd[1], { env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc = p;
    let buf = '';
    p.stdout.on('data', (d) => {
      buf += d.toString();
      const m = buf.match(/DWN_ENGINE_READY (\d+)/);
      if (m && this.state !== 'running') {
        this.port = Number(m[1]);
        this.crashes = 0;
        this.setState('running');
      }
    });
    p.stderr.pipe(log);
    p.on('error', (e) => this.setState('failed', `The download engine couldn't start: ${e.message}`));
    p.on('exit', () => {
      if (this.proc !== p) return;
      this.proc = null;
      this.port = 0;
      if (this.stopping || quitting) return this.setState('stopped');
      this.crashes += 1;
      if (this.crashes > 3) {
        return this.setState('failed', `The download engine stopped unexpectedly several times. Its log is at ${this.logPath}`);
      }
      this.start();
    });
    setTimeout(() => {
      if (this.proc === p && this.state === 'starting') {
        this.setState('failed', 'The download engine took too long to start. Try again in a moment.');
        p.kill();
      }
    }, 60000);
  },

  stop() {
    this.stopping = true;
    if (this.proc) {
      try { this.proc.stdin.end(); } catch {}
      this.proc.kill();
    }
  },

  restart() {
    this.crashes = 0;
    if (this.proc) {
      const p = this.proc;
      this.proc = null;
      this.stopping = true;
      p.kill();
    }
    this.stopping = false;
    this.start();
  },
};

async function api(p, body) {
  if (engine.state !== 'running') return { error: 'The download engine isn\'t running yet.' };
  try {
    const res = await fetch(`http://127.0.0.1:${engine.port}/${p.replace(/^\//, '')}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'X-Dwn-Token': engine.token, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => null);
    if (!res.ok) return { error: (data && data.error) || `The download engine couldn't do that (error ${res.status}).` };
    return { data };
  } catch {
    return { error: 'The download engine didn\'t respond. Try again.' };
  }
}

// ---------------------------------------------------------------- windows

function broadcast(channel, payload) {
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.isDestroyed()) w.webContents.send(channel, payload);
  }
}

const webPrefs = {
  preload: path.join(__dirname, 'preload.js'),
  contextIsolation: true,
  nodeIntegration: false,
  sandbox: true,
};

function createMain() {
  mainWin = new BrowserWindow({
    width: 1100,
    height: 760,
    minWidth: 940,
    minHeight: 680,
    show: false,
    backgroundColor: '#0b0b0c',
    title: 'Dwn',
    icon: path.join(RES, IS_WIN ? 'icon.ico' : 'icon.png'),
    titleBarStyle: 'hidden',
    titleBarOverlay: IS_WIN ? { color: '#101012', symbolColor: '#e8e8ea', height: 40 } : undefined,
    trafficLightPosition: { x: 16, y: 16 },
    webPreferences: webPrefs,
  });
  mainWin.loadFile(path.join(__dirname, 'ui', 'index.html'));
  mainWin.once('ready-to-show', () => {
    if (!process.argv.includes('--hidden') && !SNAPSHOT) mainWin.show();
  });
  mainWin.on('close', (e) => {
    // With the tray on, closing the window keeps Dwn running there.
    if (!quitting && settings.get('trayEnabled')) {
      e.preventDefault();
      mainWin.hide();
    }
  });
  mainWin.on('closed', () => { mainWin = null; });
  mainWin.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

function showMain() {
  if (!mainWin) createMain();
  if (mainWin.isMinimized()) mainWin.restore();
  mainWin.show();
  mainWin.focus();
  hidePanel();
}

// Quick panel: small frameless window in the top-right (or bottom-right) corner.
const PANEL_W = 384;
let panelAnchor = { x: 0, y: 0, top: true };

function createPanel() {
  panelWin = new BrowserWindow({
    width: PANEL_W,
    height: 420,
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    movable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    fullscreenable: false,
    hasShadow: true,
    backgroundColor: '#00000000',
    webPreferences: webPrefs,
  });
  panelWin.setAlwaysOnTop(true, 'floating');
  panelWin.loadFile(path.join(__dirname, 'ui', 'panel.html'));
  panelWin.on('blur', () => setTimeout(() => {
    if (panelWin && !panelWin.isFocused()) hidePanel();
  }, 120));
  panelWin.on('closed', () => { panelWin = null; });
}

function placePanel(height) {
  if (!panelWin) return;
  const h = Math.round(height || panelWin.getBounds().height);
  const x = panelAnchor.x - PANEL_W;
  const y = panelAnchor.top ? panelAnchor.y : panelAnchor.y - h;
  panelWin.setBounds({ x: Math.round(x), y: Math.round(y), width: PANEL_W, height: h });
}

function showPanel() {
  if (!panelWin) createPanel();
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const wa = display.workArea;
  const top = settings.get('panelPosition') !== 'bottom';
  panelAnchor = { x: wa.x + wa.width - 12, y: top ? wa.y + 12 : wa.y + wa.height - 12, top };
  placePanel();
  panelWin.webContents.send('panel:show', { clipboard: clipboard.readText() });
  panelWin.show();
  panelWin.focus();
}

function hidePanel() {
  if (panelWin && panelWin.isVisible()) panelWin.hide();
}

function togglePanel() {
  if (panelWin && panelWin.isVisible()) hidePanel();
  else showPanel();
}

// ---------------------------------------------------------------- tray, shortcut, links

function trayImage() {
  const p = path.join(RES, 'tray.png');
  const img = nativeImage.createFromPath(p);
  if (!IS_WIN) img.setTemplateImage(true);
  return img;
}

function buildTrayMenu() {
  const u = updater.state();
  return Menu.buildFromTemplate([
    { label: 'Quick Download', click: showPanel },
    { label: 'Download Copied Link', click: () => downloadClipboard() },
    { label: 'Bulk Download…', click: () => { showMain(); broadcast('ui:command', 'bulk'); } },
    { type: 'separator' },
    u.phase === 'available' || u.phase === 'ready'
      ? { label: `Update to ${u.version}…`, click: () => { showMain(); broadcast('ui:command', 'update'); } }
      : { label: 'Check for Updates…', click: () => updater.check(true) },
    { label: 'Open Dwn', click: showMain },
    { label: 'Open Download Folder', click: () => broadcast('ui:command', 'open-folder') },
    { label: 'Settings…', click: () => { showMain(); broadcast('ui:command', 'settings'); } },
    { type: 'separator' },
    { label: 'Quit Dwn', click: () => { quitting = true; app.quit(); } },
  ]);
}

function applyTray() {
  if (settings.get('trayEnabled')) {
    if (!tray) {
      tray = new Tray(trayImage());
      tray.setToolTip('Dwn');
      tray.on('click', togglePanel);
      tray.on('right-click', () => tray.popUpContextMenu(buildTrayMenu()));
      if (!IS_WIN) tray.setContextMenu(null);
    }
  } else if (tray) {
    tray.destroy();
    tray = null;
  }
}

function applyShortcut() {
  globalShortcut.unregisterAll();
  if (!settings.get('hotkeyEnabled')) return { ok: true };
  const acc = settings.get('shortcut');
  try {
    const ok = globalShortcut.register(acc, () => {
      if (settings.get('shortcutAction') === 'instant') downloadClipboard();
      else togglePanel();
    });
    return ok ? { ok: true } : { ok: false, error: `Another app is already using ${acc}.` };
  } catch (e) {
    return { ok: false, error: `That shortcut can't be used: ${e.message}` };
  }
}

async function downloadClipboard() {
  const text = clipboard.readText().trim();
  const links = text.split(/\s+/).filter((l) => /^(https?:\/\/|[a-z0-9-]+(\.[a-z0-9-]+)+\/)/i.test(l));
  if (links.length > 1) {
    showMain();
    broadcast('ui:command', { bulk: links.join('\n') });
    return;
  }
  if (!links.length) return notify('No link on the clipboard', 'Copy a video\'s link, then try again.');
  const url = links[0].startsWith('http') ? links[0] : `https://${links[0]}`;
  const r = await api('download', { url });
  if (r.error) notify('Couldn\'t download', r.error);
  else notify('Download started', url);
}

function handleLink(argvOrUrl) {
  const list = Array.isArray(argvOrUrl) ? argvOrUrl : [argvOrUrl];
  const link = list.find((a) => typeof a === 'string' && a.startsWith('dwn://'));
  if (!link) return false;
  try {
    const u = new URL(link);
    const target = u.searchParams.get('url');
    if (target) {
      const kind = u.searchParams.get('kind') || undefined;
      api('download', { url: target, kind }).then((r) => {
        notify(r.error ? 'Couldn\'t download' : 'Download started', r.error || target);
      });
    }
  } catch {}
  return true;
}

function notify(title, body, onClick) {
  if (!Notification.isSupported()) return;
  const n = new Notification({ title, body, icon: path.join(RES, 'icon.png'), silent: false });
  if (onClick) n.on('click', onClick);
  n.show();
}

// ---------------------------------------------------------------- IPC

ipcMain.handle('api', (_e, p, body) => api(p, body));
ipcMain.handle('engine:state', () => ({ state: engine.state, message: engine.message }));
ipcMain.handle('engine:restart', () => engine.restart());
ipcMain.handle('engine:log', () => shell.showItemInFolder(engine.logPath));

ipcMain.handle('settings:get', () => settings.all());
ipcMain.handle('settings:set', (_e, patch) => {
  settings.set(patch);
  if ('trayEnabled' in patch) applyTray();
  if ('launchAtLogin' in patch) app.setLoginItemSettings({ openAtLogin: !!patch.launchAtLogin, args: ['--hidden'] });
  let shortcut = { ok: true };
  if ('shortcut' in patch || 'hotkeyEnabled' in patch) shortcut = applyShortcut();
  broadcast('settings', settings.all());
  return { settings: settings.all(), shortcut };
});
ipcMain.handle('shortcut:pause', () => globalShortcut.unregisterAll());
ipcMain.handle('shortcut:resume', () => applyShortcut());

ipcMain.handle('clipboard:read', () => clipboard.readText());
ipcMain.handle('clipboard:write', (_e, t) => clipboard.writeText(String(t)));

ipcMain.handle('shell:open', async (_e, p) => {
  if (!p || !fs.existsSync(p)) return { error: 'That file isn\'t there anymore.' };
  const err = await shell.openPath(p);
  return err ? { error: err } : {};
});
ipcMain.handle('shell:reveal', (_e, p) => {
  if (!p || !fs.existsSync(p)) return { error: 'That file isn\'t there anymore.' };
  shell.showItemInFolder(p);
  return {};
});
ipcMain.handle('shell:folder', (_e, p) => {
  fs.mkdirSync(p, { recursive: true });
  return shell.openPath(p);
});
ipcMain.handle('shell:external', (_e, url) => {
  if (/^https:\/\//.test(url)) shell.openExternal(url);
});
ipcMain.handle('shell:trash', async (_e, p) => {
  try { await shell.trashItem(p); return {}; } catch { return { error: 'Couldn\'t move that to the Recycle Bin.' }; }
});
ipcMain.handle('fs:exists', (_e, p) => !!p && fs.existsSync(p));
ipcMain.handle('fs:free', (_e, p) => {
  try {
    let dir = p;
    while (dir && !fs.existsSync(dir)) dir = path.dirname(dir);
    const s = fs.statfsSync(dir);
    return s.bavail * s.bsize;
  } catch { return null; }
});

ipcMain.handle('dialog:folder', async (_e, current) => {
  const r = await dialog.showOpenDialog(mainWin, {
    title: 'Choose where Dwn saves downloads', defaultPath: current, properties: ['openDirectory', 'createDirectory'],
  });
  return r.canceled ? null : r.filePaths[0];
});
ipcMain.handle('dialog:textfile', async () => {
  const r = await dialog.showOpenDialog(mainWin, {
    title: 'Choose a text or CSV file with links in it', properties: ['openFile'],
    filters: [{ name: 'Text or CSV', extensions: ['txt', 'csv', 'text', 'md'] }],
  });
  if (r.canceled) return null;
  const st = fs.statSync(r.filePaths[0]);
  if (st.size > 5_000_000) return { error: 'That file is too big. 5 MB max.' };
  return { text: fs.readFileSync(r.filePaths[0], 'utf8') };
});

ipcMain.handle('oembed', async (_e, url) => {
  try {
    const r = await fetch(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(url)}`);
    if (!r.ok) return null;
    const j = await r.json();
    return { title: j.title, author: j.author_name };
  } catch { return null; }
});

ipcMain.handle('notify', (_e, title, body, file) => {
  notify(title, body, file ? () => shell.showItemInFolder(file) : undefined);
});

ipcMain.handle('browsers', () => detectBrowsers());
ipcMain.handle('browser:open', (_e, id, url) => {
  const b = detectBrowsers().find((x) => x.id === id);
  if (!b) return;
  if (IS_WIN) spawn(b.exe, [url], { detached: true, stdio: 'ignore' }).unref();
  else spawn('open', ['-a', b.exe, url], { detached: true, stdio: 'ignore' }).unref();
});

ipcMain.handle('panel:hide', () => hidePanel());
ipcMain.handle('panel:size', (_e, h) => { if (panelWin && panelWin.isVisible()) placePanel(h); else if (panelWin) placePanel(h); });
ipcMain.handle('main:show', (_e, command) => {
  showMain();
  if (command) setTimeout(() => broadcast('ui:command', command), 150);
});

ipcMain.handle('update:state', () => updater.state());
ipcMain.handle('update:check', () => updater.check(true));
ipcMain.handle('update:install', () => updater.install());
ipcMain.handle('app:version', () => app.getVersion());
ipcMain.handle('app:platform', () => process.platform);

function detectBrowsers() {
  const pf = process.env.ProgramFiles || 'C:\\Program Files';
  const pf86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const local = process.env.LOCALAPPDATA || '';
  const cands = IS_WIN ? [
    ['firefox', 'Firefox', [`${pf}\\Mozilla Firefox\\firefox.exe`, `${pf86}\\Mozilla Firefox\\firefox.exe`]],
    ['chrome', 'Chrome', [`${pf}\\Google\\Chrome\\Application\\chrome.exe`, `${pf86}\\Google\\Chrome\\Application\\chrome.exe`, `${local}\\Google\\Chrome\\Application\\chrome.exe`]],
    ['edge', 'Edge', [`${pf86}\\Microsoft\\Edge\\Application\\msedge.exe`, `${pf}\\Microsoft\\Edge\\Application\\msedge.exe`]],
    ['brave', 'Brave', [`${pf}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`, `${local}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`]],
  ] : [
    ['firefox', 'Firefox', ['/Applications/Firefox.app']],
    ['chrome', 'Chrome', ['/Applications/Google Chrome.app']],
    ['edge', 'Edge', ['/Applications/Microsoft Edge.app']],
    ['brave', 'Brave', ['/Applications/Brave Browser.app']],
  ];
  return cands
    .map(([id, name, paths]) => ({ id, name, exe: paths.find((p) => p && fs.existsSync(p)) }))
    .filter((b) => b.exe);
}

// ---------------------------------------------------------------- lifecycle

app.setAppUserModelId('com.yuvrajgarg.dwn');
if (app.isPackaged) app.setAsDefaultProtocolClient('dwn');

app.on('second-instance', (_e, argv) => {
  if (!handleLink(argv)) showMain();
});
app.on('open-url', (e, url) => { e.preventDefault(); handleLink(url); });

app.whenReady().then(() => {
  engine.start();
  createMain();
  applyTray();
  applyShortcut();
  updater.init({
    onChange: (s) => { broadcast('update', s); },
    notify: (title, body) => notify(title, body, () => { showMain(); broadcast('ui:command', 'update'); }),
  });
  handleLink(process.argv);
  if (SNAPSHOT) runSnapshots();
});

// Development aid: render windows hidden and save screenshots, then quit.
async function runSnapshots() {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const shot = async (win, name) => {
    const img = await win.webContents.capturePage();
    fs.writeFileSync(path.join(SNAPSHOT, `${name}.png`), img.toPNG());
  };
  const steps = (process.env.DWN_SNAPSHOT_STEPS || 'splash,welcome,main,panel').split(',');
  await wait(900); if (steps.includes('splash')) await shot(mainWin, 'splash');
  await wait(2600); if (steps.includes('welcome')) await shot(mainWin, 'welcome');
  if (steps.includes('main')) {
    settings.set({ onboarded: true });
    mainWin.reload();
    await wait(3500);
    await shot(mainWin, 'main');
    if (process.env.DWN_SNAPSHOT_LINK) {
      await mainWin.webContents.executeJavaScript(`C.input.value=${JSON.stringify(process.env.DWN_SNAPSHOT_LINK)};onLinkChange();`);
      await wait(5000);
      await shot(mainWin, 'main-link');
      if (steps.includes('section')) {
        await mainWin.webContents.executeJavaScript('openSection(S.info)');
        await wait(6000);
        await shot(mainWin, 'section');
      }
      if (steps.includes('settings')) {
        await mainWin.webContents.executeJavaScript('document.querySelectorAll(".modal-back").forEach(m=>m.remove());openSettings("shortcut")');
        await wait(800);
        await shot(mainWin, 'settings');
      }
    }
  }
  if (steps.includes('panel')) {
    createPanel();
    await wait(1500);
    panelWin.webContents.send('panel:show', { clipboard: process.env.DWN_SNAPSHOT_LINK || '' });
    await wait(5000);
    await shot(panelWin, 'panel');
  }
  quitting = true;
  app.quit();
}

app.on('activate', () => showMain());
app.on('window-all-closed', () => {
  if (!settings.get('trayEnabled')) { quitting = true; app.quit(); }
});
app.on('before-quit', () => { quitting = true; });
app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  engine.stop();
});

module.exports = { api };
