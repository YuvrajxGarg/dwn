// The only bridge between the UI and the main process.
const { contextBridge, ipcRenderer } = require('electron');

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
});
