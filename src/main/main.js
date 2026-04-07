const { app, Tray, Menu, BrowserWindow, ipcMain, clipboard, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const { exec } = require('child_process');
const { GlobalKeyboardListener } = require('node-global-key-listener');

const settingsManager = require('./settingsManager');
const groqService = require('./groqService');

// Attempt to load services with fallbacks to avoid crashing if they don't exist yet
let DeepgramService;
let deepgramService;
let balanceService;

try {
  DeepgramService = require('./deepgramService');
  deepgramService = new DeepgramService();
} catch (e) {
  console.warn("[Main] Could not load deepgramService. Using mock interface.", e.message);
  deepgramService = {
    connect: () => {},
    close: () => {},
    sendAudio: () => {},
    onTranscript: null
  };
}

try {
  balanceService = require('./balanceService');
} catch (e) {
  console.warn("[Main] Could not load balanceService. Using mock interface.", e.message);
  balanceService = {
    fetchDeepgramBalance: async () => null,
    fetchGroqStatus: async () => null
  };
}

// Global state tracking
let tray = null;
let settingsWindow = null;
let overlayWindow = null;
let keyboardListener = null;
let isRecording = false;

// 7. Handle Deepgram transcripts
deepgramService.onTranscript = async (transcript) => {
  if (!transcript || transcript.trim() === '') return;

  const settings = settingsManager.load();
  let finalText = transcript;

  const useGroq = settings.GROQ_SPELLING_CORRECTION || 
                  settings.GROQ_GRAMMAR_CORRECTION || 
                  settings.GROQ_TRANSLITERATION || 
                  settings.GROQ_TRANSLATION;

  if (useGroq) {
    finalText = await groqService.processTranscript(transcript, settings);
  }

  // Inject text via clipboard + PowerShell SendKeys Ctrl+V
  const previousClip = clipboard.readText();
  clipboard.writeText(finalText);

  const psScript = `Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('^v')`;
  exec(`powershell -NoProfile -Command "${psScript}"`, (error) => {
    if (error) {
      console.error('[Main] Failed to inject text via PowerShell:', error);
    }

    // Restore clipboard after 500ms
    setTimeout(() => {
      clipboard.writeText(previousClip);
    }, 500);
  });
};

function handleKeyDown() {
  isRecording = true;
  const settings = settingsManager.load();
  
  if (typeof deepgramService.connect === 'function') {
    deepgramService.connect(settings);
  }

  if (!overlayWindow) {
    createOverlayWindow();
  }
  overlayWindow.show();

  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.webContents.send('start-recording');
  }
  if (overlayWindow && !overlayWindow.isDestroyed()) {
    overlayWindow.webContents.send('start-recording');
  }
}

function handleKeyUp() {
  isRecording = false;
  
  if (typeof deepgramService.close === 'function') {
    deepgramService.close();
  }

  if (overlayWindow && !overlayWindow.isDestroyed()) {
    overlayWindow.hide();
  }

  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.webContents.send('stop-recording');
  }
  if (overlayWindow && !overlayWindow.isDestroyed()) {
    overlayWindow.webContents.send('stop-recording');
  }
}

// 3. Listen Globally for HOTKEY
function startKeyListener(hotkeyStr) {
  if (keyboardListener) {
    keyboardListener.kill();
    keyboardListener = null;
  }
  
  if (!hotkeyStr) return;

  keyboardListener = new GlobalKeyboardListener();
  let isKeyDown = false;

  keyboardListener.addListener((e) => {
    // Both mapped to uppercase to assure safe loose comparison
    if (e.name && e.name.toUpperCase() === hotkeyStr.toUpperCase()) {
      if (e.state === 'DOWN' && !isKeyDown) {
        isKeyDown = true;
        handleKeyDown();
      } else if (e.state === 'UP' && isKeyDown) {
        isKeyDown = false;
        handleKeyUp();
      }
    }
  });
}

function createOverlayWindow() {
  overlayWindow = new BrowserWindow({
    width: 250,
    height: 100,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, '..', 'renderer', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  overlayWindow.loadFile(path.join(__dirname, '..', 'renderer', 'overlay.html'));
  
  overlayWindow.on('closed', () => {
    overlayWindow = null;
  });
}

function openSettingsWindow() {
  if (settingsWindow) {
    if (settingsWindow.isMinimized()) settingsWindow.restore();
    settingsWindow.focus();
    return;
  }
  
  settingsWindow = new BrowserWindow({
    width: 650,
    height: 750,
    webPreferences: {
      preload: path.join(__dirname, '..', 'renderer', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  settingsWindow.loadFile(path.join(__dirname, '..', 'renderer', 'settings.html'));

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}

// 1. Create a system tray icon
function setupTray() {
  const iconPath = path.join(__dirname, '..', '..', 'resources', 'tray-icon.png');
  let icon;
  
  if (fs.existsSync(iconPath)) {
    icon = nativeImage.createFromPath(iconPath);
  } else {
    // Graceful fallback
    icon = nativeImage.createEmpty();
  }

  tray = new Tray(icon);

  const contextMenu = Menu.buildFromTemplate([
    { label: 'Settings', click: () => openSettingsWindow() },
    { type: 'separator' },
    // 15. Quit only from tray menu
    { 
      label: 'Quit', 
      click: () => {
        app.isQuitting = true;
        app.quit();
      }
    }
  ]);

  tray.setToolTip('VocalFlow');
  tray.setContextMenu(contextMenu);
  
  // 2. Tray left-click opens Settings
  tray.on('click', () => {
    openSettingsWindow();
  });
}

app.whenReady().then(() => {
  setupTray();

  const settings = settingsManager.load();
  startKeyListener(settings.HOTKEY || 'LEFT ALT'); 
});

// App lifecycle & IPC handlers

// 14. Prevent quit on window close (tray app)
app.on('window-all-closed', (e) => {
  e.preventDefault();
});

// 6. Receive Audio Chunk and Forward
ipcMain.on('audio-chunk', (event, buffer) => {
  if (isRecording && typeof deepgramService.sendAudio === 'function') {
    deepgramService.sendAudio(buffer);
  }
});

// 8. Get Settings IPC
ipcMain.handle('get-settings', () => {
  return settingsManager.load();
});

// 9. Save Settings + Restart Hotkey listener
ipcMain.handle('save-settings', (event, newSettings) => {
  const success = settingsManager.save(newSettings);
  if (success && newSettings.HOTKEY) {
    startKeyListener(newSettings.HOTKEY);
  }
  return success;
});

// 10. Fetch Deepgram Balance
ipcMain.handle('fetch-deepgram-balance', async (event, key) => {
  if (typeof balanceService.fetchDeepgramBalance === 'function') {
    return await balanceService.fetchDeepgramBalance(key);
  }
  return null;
});

// 11. Fetch Groq Status
ipcMain.handle('fetch-groq-status', async (event, key) => {
  if (typeof balanceService.fetchGroqStatus === 'function') {
    return await balanceService.fetchGroqStatus(key);
  }
  return null;
});

// 12. Fetch Deepgram Models
ipcMain.handle('fetch-deepgram-models', async (event, key) => {
  return new Promise((resolve) => {
    const options = {
      hostname: 'api.deepgram.com',
      path: '/v1/models',
      method: 'GET',
      headers: {
        'Authorization': `Token ${key}`
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.models) {
            resolve(json.models.map(m => m.name));
          } else {
            resolve([]);
          }
        } catch (e) {
          resolve([]);
        }
      });
    });

    req.on('error', () => resolve([]));
    req.end();
  });
});

// 13. Fetch Groq Models
ipcMain.handle('fetch-groq-models', async (event, key) => {
  return new Promise((resolve) => {
    const options = {
      hostname: 'api.groq.com',
      path: '/openai/v1/models',
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${key}`
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.data) {
            resolve(json.data.map(m => m.id));
          } else {
            resolve([]);
          }
        } catch (e) {
          resolve([]);
        }
      });
    });

    req.on('error', () => resolve([]));
    req.end();
  });
});
