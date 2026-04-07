const { app } = require('electron');
const path = require('path');
const fs = require('fs');

function getSettingsPath() {
  // app.getPath("userData") typically maps to %APPDATA%\<YourApp> on Windows
  return path.join(app.getPath("userData"), 'settings.json');
}

function load() {
  let defaults = {};
  
  try {
    // Load defaults from config.js
    defaults = require('../../config/config.js');
  } catch (error) {
    console.warn('[SettingsManager] Could not require ../../config/config.js:', error.message);
  }

  const settingsPath = getSettingsPath();

  try {
    if (fs.existsSync(settingsPath)) {
      const data = fs.readFileSync(settingsPath, 'utf8');
      const savedSettings = JSON.parse(data);
      
      // Merge saved settings over defaults
      return { ...defaults, ...savedSettings };
    }
  } catch (error) {
    console.error('[SettingsManager] Missing or corrupt settings.json. Returning defaults.', error.message);
  }

  // Return defaults only if file is missing or corrupt
  return { ...defaults };
}

function save(settings) {
  const settingsPath = getSettingsPath();
  
  try {
    // Ensure the directory exists before writing
    const dir = path.dirname(settingsPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    
    // Write JSON file with formatting for readability
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8');
    return true;
  } catch (error) {
    console.error('[SettingsManager] Failed to save settings to JSON:', error.message);
    return false;
  }
}

module.exports = {
  load,
  save
};
