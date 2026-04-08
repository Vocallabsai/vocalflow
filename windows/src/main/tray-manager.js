const { Tray, Menu, nativeImage, app, BrowserWindow } = require('electron');
const path = require('path');

let tray = null;
let mainWindow = null;

function createTray(windowRef) {
  mainWindow = windowRef;
  const iconPath = path.join(__dirname, '../../resources/icon.png');
  const icon = nativeImage.createFromPath(iconPath);
  
  tray = new Tray(icon);
  const contextMenu = Menu.buildFromTemplate([
    { label: 'Settings', click: () => { mainWindow.show(); } },
    { type: 'separator' },
    { label: 'Quit', click: () => { app.isQuitting = true; app.quit(); } }
  ]);
  
  tray.setToolTip('VocalFlow');
  tray.setContextMenu(contextMenu);
  
  tray.on('click', () => {
    mainWindow.isVisible() ? mainWindow.hide() : mainWindow.show();
  });
  
  return tray;
}

function updateTrayIcon(isRecording) {
  if (!tray) return;
  const iconPath = path.join(__dirname, `../../resources/${isRecording ? 'icon-recording.png' : 'icon.png'}`);
  tray.setImage(nativeImage.createFromPath(iconPath));
}

module.exports = { createTray, updateTrayIcon };
