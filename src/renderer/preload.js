const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('vocalflow', {
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (s) => ipcRenderer.invoke('save-settings', s),
  fetchDeepgramBalance: (key) => ipcRenderer.invoke('fetch-deepgram-balance', key),
  fetchGroqStatus: (key) => ipcRenderer.invoke('fetch-groq-status', key),
  fetchDeepgramModels: (key) => ipcRenderer.invoke('fetch-deepgram-models', key),
  fetchGroqModels: (key) => ipcRenderer.invoke('fetch-groq-models', key),
  sendAudioChunk: (buffer) => ipcRenderer.send('audio-chunk', buffer),
  
  // Safely wrap IPC event listeners by stripping the IpcRendererEvent
  // object so that the renderer process only gets the necessary arguments.
  onStartRecording: (cb) => ipcRenderer.on('start-recording', (_event, ...args) => cb(...args)),
  onStopRecording: (cb) => ipcRenderer.on('stop-recording', (_event, ...args) => cb(...args))
});
