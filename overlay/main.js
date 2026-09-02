// NerdSidekiq overlay — the app's main window (hesoyam UI): mode picker,
// live captions, streamed answers, mock-interview coach.
// The python loops and the Swift app POST events to
// http://127.0.0.1:17865/assist:
//   {type:"captions", lines}     -> refresh the captions/dialogue sidebar
//   {type:"question", question}  -> new answer/feedback starts
//   {type:"delta", text}         -> append streamed text
//   {type:"done"}                -> finalize the stream
//   {type:"status", text}        -> footer status line
//   {type:"phase", phase, ...}   -> recorder state (recording/processing/saved/error)
//   {type:"ui", action, ...}     -> test hook: drive the UI headlessly
// The renderer controls the recorder via the 'control' IPC channel:
// it writes <base>/session.json and posts a darwin notification.
const { app, BrowserWindow, screen, ipcMain } = require('electron');
const { execFile } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 17865;
const BASE = path.resolve(__dirname, '..');
let win = null;
let savedBounds = null; // full-window bounds while minimized to the pill bar

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win && !win.isDestroyed()) win.showInactive(); });
}

function createWindow() {
  const { width } = screen.getPrimaryDisplay().workAreaSize;
  win = new BrowserWindow({
    width: 880,
    height: 640,
    x: width - 900,
    y: 60,
    minWidth: 600,
    minHeight: 440,
    frame: false,
    transparent: false,
    backgroundColor: '#101012',
    roundedCorners: true,
    resizable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: true,
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

function notifyRecorder(event) {
  execFile('/usr/bin/notifyutil', ['-p', `dev.cyberjosef.nerdsidekiq.${event}`]);
}

ipcMain.handle('control', (_e, msg) => {
  if (msg.cmd === 'start') {
    const session = {
      mode: msg.mode || 'transcript',
      about: msg.about || '',
      notes_path: msg.notes_path || '',
    };
    fs.writeFileSync(path.join(BASE, 'session.json'),
      JSON.stringify(session, null, 2));
    notifyRecorder('start');
  } else if (msg.cmd === 'finish') {
    notifyRecorder('finish');
  } else if (msg.cmd === 'settings') {
    notifyRecorder('settings');
  } else if (msg.cmd === 'compact') {
    // transcript session minimized to a pill bar (design 2e)
    if (win && !savedBounds) {
      savedBounds = win.getBounds();
      win.setMinimumSize(100, 47);
      win.setBounds({ x: savedBounds.x + savedBounds.width - 250,
                      y: savedBounds.y, width: 250, height: 47 });
    }
  } else if (msg.cmd === 'restore') {
    if (win && savedBounds) {
      win.setBounds(savedBounds);
      win.setMinimumSize(600, 440);
      savedBounds = null;
    }
  } else if (msg.cmd === 'quit') {
    // the ✕ button: quit the whole app (Swift recorder + this overlay).
    // Only an explicit user click sends this — never window teardown,
    // otherwise a dying old instance would kill a freshly started app.
    notifyRecorder('quit');
    app.quit();
  }
  return true;
});

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
  server.on('error', (e) => {
    // another overlay already owns the port -> it stays, we leave
    if (e.code === 'EADDRINUSE') app.quit();
  });
  server.listen(PORT, '127.0.0.1');
}

app.dock?.hide();
app.whenReady().then(() => {
  createWindow();
  startServer();
});
app.on('window-all-closed', () => app.quit());
