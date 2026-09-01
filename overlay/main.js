// NerdSidekiq overlay — an always-on-top assistant window (hesoyam UI):
// live captions sidebar + streaming answer. live_loop.py POSTs events to
// http://127.0.0.1:17865/assist:
//   {type:"captions", lines}     -> refresh the captions sidebar
//   {type:"question", question}  -> new answer starts (auto-detected)
//   {type:"delta", text}         -> append streamed answer text
//   {type:"done"}                -> finalize the answer
const { app, BrowserWindow, screen } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 17865;
let win = null;

function createWindow() {
  const { width } = screen.getPrimaryDisplay().workAreaSize;
  win = new BrowserWindow({
    width: 640,
    height: 560,
    x: width - 660,
    y: 60,
    minWidth: 380,
    minHeight: 300,
    frame: false,
    transparent: true,
    resizable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.setAlwaysOnTop(true, 'floating');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.loadFile('index.html');
  win.showInactive(); // never steal focus from the call
}

function startServer() {
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/shot') {
      // debug: window screenshot -> PNG (used by tests)
      if (!win || win.isDestroyed()) { res.writeHead(503); res.end(); return; }
      win.webContents.capturePage().then((img) => {
        res.writeHead(200, { 'Content-Type': 'image/png' });
        res.end(img.toPNG());
      }).catch(() => { res.writeHead(500); res.end(); });
      return;
    }
    if (req.method !== 'POST' || req.url !== '/assist') {
      res.writeHead(404); res.end(); return;
    }
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      try {
        const event = JSON.parse(body);
        if (event.type !== 'captions' && event.type !== 'delta') {
          fs.appendFileSync(path.join(__dirname, 'assist.log'),
            JSON.stringify({ t: new Date().toISOString(), ...event }) + '\n');
        }
        if (win && !win.isDestroyed()) {
          win.webContents.send('assist', event);
          if (event.type === 'question') win.showInactive();
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"ok":true}');
      } catch {
        res.writeHead(400); res.end();
      }
    });
  });
  server.listen(PORT, '127.0.0.1');
}

app.dock?.hide();
app.whenReady().then(() => {
  createWindow();
  startServer();
});
app.on('window-all-closed', () => app.quit());
