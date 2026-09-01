const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('nerdsidekiq', {
  onAssist: (cb) => ipcRenderer.on('assist', (_e, event) => cb(event)),
});
