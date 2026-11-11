// App-level settings (engine preferences live in the engine's prefs.json).
const { app } = require('electron');
const fs = require('fs');
const path = require('path');

const DEFAULTS = {
  onboarded: false,
  tab: 'video',
  optionsOpen: true,
  hotkeyEnabled: true,
  shortcut: process.platform === 'win32' ? 'Alt+Shift+D' : 'Alt+Command+D',
  shortcutAction: 'panel',     // panel | instant
  panelPosition: 'top',        // top | bottom
  trayEnabled: true,
  launchAtLogin: false,
  autoCheckUpdates: true,
  autoInstallUpdates: true,   // download in the background, install on quit
  notifiedVersion: '',
  section: 'links',            // links | cloud (the switch at the top of the window)
  cloudLocalFolder: '',        // the This PC pane's folder ('' = the download folder)
  cloudLinks: [],              // Drive folder links kept in the Cloud sidebar: {account, link, title}
  doneSound: true,             // play a sound when a download finishes
  donePanel: 'bottom-right',   // off | bottom-right | top-right | bottom-left | top-left
};

let file = null;
let data = null;

function load() {
  if (data) return;
  file = path.join(app.getPath('userData'), 'settings.json');
  try { data = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(file, 'utf8')) }; } catch { data = { ...DEFAULTS }; }
}

function save() {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file + '.tmp', JSON.stringify(data, null, 1));
  fs.renameSync(file + '.tmp', file);
}

module.exports = {
  get(k) { load(); return data[k]; },
  all() { load(); return { ...data }; },
  set(patch) {
    load();
    for (const [k, v] of Object.entries(patch || {})) if (k in DEFAULTS) data[k] = v;
    save();
  },
};
