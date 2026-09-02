const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('nerdsidekiq', {
  onAssist: (cb) => ipcRenderer.on('assist', (_e, event) => cb(event)),
  control: (msg) => ipcRenderer.invoke('control', msg),
});
