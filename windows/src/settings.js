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
  notifiedVersion: '',
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
