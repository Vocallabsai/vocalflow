const { app, BrowserWindow, ipcMain, screen } = require('electron');
const path = require('path');
const fs = require('fs');

// Set user data and cache paths to a local folder to avoid permission issues
const userDataPath = path.join(process.cwd(), 'electron-data');
if (!fs.existsSync(userDataPath)) {
    fs.mkdirSync(userDataPath, { recursive: true });
}
app.setPath('userData', userDataPath);
app.setPath('sessionData', path.join(userDataPath, 'session'));

const store = require('./store');
const { createTray, updateTrayIcon } = require('./tray-manager');
const hotkeyManager = require('./hotkey-manager');
const audioManager = require('./audio-manager');
const deepgramService = require('./deepgram-service');
const groqService = require('./groq-service');
const balanceService = require('./balance-service');
const textInjector = require('./text-injector');

let mainWindow = null;
let isRecording = false;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 450,
    height: 650,
    show: false,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

  mainWindow.on('blur', () => {
    mainWindow.hide();
  });
}

app.whenReady().then(() => {
  createWindow();
  createTray(mainWindow);

  // Start listening for hotkeys
  hotkeyManager.startListening(store, onRecordStart, onRecordEnd);

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

function onRecordStart() {
  if (isRecording) return;
  isRecording = true;
  updateTrayIcon(true);

  deepgramService.connect(
    store.get('deepgramApiKey'),
    store.get('selectedModel'),
    store.get('selectedLanguage'),
    onTranscriptResult
  );

  audioManager.startCapture((chunk) => {
    deepgramService.sendAudioChunk(chunk);
  });
  
  // Play start sound (optional/placeholder)
  console.log('Recording started...');
}

async function onRecordEnd() {
  if (!isRecording) return;
  isRecording = false;
  updateTrayIcon(false);

  audioManager.stopCapture();
  
  deepgramService.closeStream(async (transcript) => {
    if (!transcript) {
      console.log('No transcript received.');
      return;
    }

    const options = {
      fixSpelling: store.get('correctionModeEnabled'),
      fixGrammar: store.get('grammarCorrectionEnabled'),
      codeMix: store.get('codeMixEnabled') ? store.get('selectedCodeMix') : null,
      targetLanguage: store.get('targetLanguageEnabled') ? store.get('selectedTargetLanguage') : null
    };

    const processedText = await groqService.processText(
      transcript,
      options,
      store.get('groqApiKey'),
      store.get('selectedGroqModel')
    );

    textInjector.inject(processedText);
    console.log('Final text injected:', processedText);
  });
}

function onTranscriptResult(transcript) {
    // This is handled in deepgramService.closeStream
}

ipcMain.handle('get-settings', () => store.store);
ipcMain.handle('save-settings', (event, settings) => {
  store.set(settings);
  return { success: true };
});

ipcMain.handle('fetch-deepgram-models', async (event, apiKey) => {
  return await deepgramService.fetchModels(apiKey);
});

ipcMain.handle('fetch-groq-models', async (event, apiKey) => {
  return await groqService.fetchGroqModels(apiKey);
});

ipcMain.handle('fetch-deepgram-balance', async (event, apiKey) => {
  return await balanceService.fetchDeepgramBalance(apiKey);
});

ipcMain.on('close-window', () => mainWindow.hide());

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});
