const Store = require('electron-store');
const fs = require('fs');
const path = require('path');

// Load hardcoded config initially if settings don't exist
const configPath = path.join(__dirname, '../../config.json');
let initialConfig = {};
if (fs.existsSync(configPath)) {
  try {
    initialConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (err) {
    console.error('Failed to parse config.json:', err);
  }
}

const store = new Store({
  defaults: {
    deepgramApiKey: initialConfig.deepgramApiKey || '',
    groqApiKey: initialConfig.groqApiKey || '',
    selectedModel: 'nova-2-general',
    selectedLanguage: 'en-US',
    selectedHotkey: 'RIGHT_ALT',
    selectedGroqModel: 'llama-3.1-70b-versatile',
    correctionModeEnabled: false,
    grammarCorrectionEnabled: false,
    codeMixEnabled: false,
    selectedCodeMix: '',
    targetLanguageEnabled: false,
    selectedTargetLanguage: 'English'
  }
});

module.exports = store;
