// The only bridge between the UI and the main process.
const { contextBridge, ipcRenderer, webUtils } = require('electron');

const listen = (channel) => (fn) => {
  const h = (_e, payload) => fn(payload);
  ipcRenderer.on(channel, h);
  return () => ipcRenderer.removeListener(channel, h);
};

contextBridge.exposeInMainWorld('dwn', {
  api: (path, body) => ipcRenderer.invoke('api', path, body),
  invoke: (channel, ...args) => ipcRenderer.invoke(channel, ...args),
  onEngine: listen('engine'),
  onSettings: listen('settings'),
  onUpdate: listen('update'),
  onCommand: listen('ui:command'),
  onPanelShow: listen('panel:show'),
  onDone: listen('done:items'),
  // The path of a file dropped from Explorer (File.path is gone in Electron 32+).
  pathForFile: (file) => { try { return webUtils.getPathForFile(file) || ''; } catch { return ''; } },
  // Drag a finished download from the "Download complete" panel into another app.
  startDrag: (file) => ipcRenderer.send('done:drag', file),
});
