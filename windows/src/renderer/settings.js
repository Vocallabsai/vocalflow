const { ipcRenderer } = require('electron');

const deepgramApiKey = document.getElementById('deepgramApiKey');
const groqApiKey = document.getElementById('groqApiKey');
const deepgramBalance = document.getElementById('deepgramBalance');
const selectedModel = document.getElementById('selectedModel');
const selectedLanguage = document.getElementById('selectedLanguage');
const correctionModeEnabled = document.getElementById('correctionModeEnabled');
const grammarCorrectionEnabled = document.getElementById('grammarCorrectionEnabled');
const codeMixEnabled = document.getElementById('codeMixEnabled');
const codeMixDropdown = document.getElementById('codeMixDropdown');
const selectedCodeMix = document.getElementById('selectedCodeMix');
const targetLanguageEnabled = document.getElementById('targetLanguageEnabled');
const targetLanguageDropdown = document.getElementById('targetLanguageDropdown');
const selectedTargetLanguage = document.getElementById('selectedTargetLanguage');
const selectedHotkey = document.getElementById('selectedHotkey');

const saveDeepgram = document.getElementById('saveDeepgram');
const saveGroq = document.getElementById('saveGroq');
const showDeepgramKey = document.getElementById('showDeepgramKey');
const showGroqKey = document.getElementById('showGroqKey');

const codeMixOptions = [
    "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
    "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
    "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais"
];

const targetLanguages = [
    "English", "Hindi", "Spanish", "French", "German",
    "Portuguese", "Japanese", "Korean", "Arabic", "Bengali",
    "Tamil", "Telugu", "Kannada", "Marathi", "Punjabi",
    "Russian", "Chinese (Simplified)", "Italian", "Dutch", "Swahili",
    "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
    "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
    "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais"
];

// Initialize UI
window.onload = async () => {
    const settings = await ipcRenderer.invoke('get-settings');
    deepgramApiKey.value = settings.deepgramApiKey;
    groqApiKey.value = settings.groqApiKey;
    correctionModeEnabled.checked = settings.correctionModeEnabled;
    grammarCorrectionEnabled.checked = settings.grammarCorrectionEnabled;
    codeMixEnabled.checked = settings.codeMixEnabled;
    targetLanguageEnabled.checked = settings.targetLanguageEnabled;
    selectedHotkey.value = settings.selectedHotkey;
    
    if (settings.codeMixEnabled) codeMixDropdown.classList.remove('hidden');
    if (settings.targetLanguageEnabled) targetLanguageDropdown.classList.remove('hidden');

    // Populate dropdowns
    codeMixOptions.forEach(opt => {
        const el = document.createElement('option');
        el.value = opt; el.textContent = opt;
        selectedCodeMix.appendChild(el);
    });
    selectedCodeMix.value = settings.selectedCodeMix;

    targetLanguages.forEach(lang => {
        const el = document.createElement('option');
        el.value = lang; el.textContent = lang;
        selectedTargetLanguage.appendChild(el);
    });
    selectedTargetLanguage.value = settings.selectedTargetLanguage;

    if (settings.deepgramApiKey) {
        updateBalance(settings.deepgramApiKey);
        fetchModels(settings.deepgramApiKey, settings.selectedModel, settings.selectedLanguage);
    }
};

async function updateBalance(apiKey) {
    if (!apiKey) return;
    deepgramBalance.textContent = 'Balance: Fetching...';
    try {
        const balance = await ipcRenderer.invoke('fetch-deepgram-balance', apiKey);
        if (balance) {
            deepgramBalance.textContent = `Balance: $${balance.amount.toFixed(2)} ${balance.currency}`;
        } else {
            deepgramBalance.textContent = 'Balance: Error / Invalid Key';
        }
    } catch (err) {
        deepgramBalance.textContent = 'Balance: Timeout / Network Error';
    }
}

async function fetchModels(apiKey, currentModel, currentLang) {
    if (!apiKey) return;
    selectedModel.innerHTML = '<option>Loading models...</option>';
    try {
        const models = await ipcRenderer.invoke('fetch-deepgram-models', apiKey);
        selectedModel.innerHTML = '';
        
        if (!models || models.length === 0) {
            const el = document.createElement('option');
            el.textContent = 'No models found (Check Key)';
            selectedModel.appendChild(el);
            return;
        }

        models.forEach(m => {
            const el = document.createElement('option');
            el.value = m.canonicalName; el.textContent = m.displayName;
            selectedModel.appendChild(el);
        });
        
        if (currentModel) selectedModel.value = currentModel;
        
        updateLanguages(models, selectedModel.value || models[0].canonicalName, currentLang);
        
        selectedModel.onchange = () => {
            updateLanguages(models, selectedModel.value, '');
            saveAll();
        };
    } catch (err) {
        selectedModel.innerHTML = '<option>Error loading models</option>';
    }
}

function updateLanguages(models, canonicalName, currentLang) {
    if (!models || models.length === 0) return;
    const model = models.find(m => m.canonicalName === canonicalName);
    selectedLanguage.innerHTML = '';
    if (model) {
        model.languages.forEach(lang => {
            const el = document.createElement('option');
            el.value = lang; el.textContent = lang;
            selectedLanguage.appendChild(el);
        });
        if (currentLang && model.languages && model.languages.includes(currentLang)) {
            selectedLanguage.value = currentLang;
        }
    }
}

// Event Listeners
saveDeepgram.onclick = async () => {
    await saveAll();
    updateBalance(deepgramApiKey.value);
    fetchModels(deepgramApiKey.value, selectedModel.value, selectedLanguage.value);
};

saveGroq.onclick = async () => {
    await saveAll();
    await ipcRenderer.invoke('fetch-groq-models', groqApiKey.value);
};

showDeepgramKey.onclick = () => {
    deepgramApiKey.type = deepgramApiKey.type === 'password' ? 'text' : 'password';
    showDeepgramKey.textContent = deepgramApiKey.type === 'password' ? 'Show' : 'Hide';
};

showGroqKey.onclick = () => {
    groqApiKey.type = groqApiKey.type === 'password' ? 'text' : 'password';
    showGroqKey.textContent = groqApiKey.type === 'password' ? 'Show' : 'Hide';
};

codeMixEnabled.onchange = () => {
    codeMixDropdown.classList.toggle('hidden', !codeMixEnabled.checked);
    saveAll();
};

targetLanguageEnabled.onchange = () => {
    targetLanguageDropdown.classList.toggle('hidden', !targetLanguageEnabled.checked);
    saveAll();
};

// Generic save
async function saveAll() {
    const settings = {
        deepgramApiKey: deepgramApiKey.value.trim(),
        groqApiKey: groqApiKey.value.trim(),
        selectedModel: selectedModel.value,
        selectedLanguage: selectedLanguage.value,
        correctionModeEnabled: correctionModeEnabled.checked,
        grammarCorrectionEnabled: grammarCorrectionEnabled.checked,
        codeMixEnabled: codeMixEnabled.checked,
        selectedCodeMix: selectedCodeMix.value,
        targetLanguageEnabled: targetLanguageEnabled.checked,
        selectedTargetLanguage: selectedTargetLanguage.value,
        selectedHotkey: selectedHotkey.value
    };
    await ipcRenderer.invoke('save-settings', settings);
}

// Auto-save on change for selectors
[selectedModel, selectedLanguage, selectedCodeMix, selectedTargetLanguage, selectedHotkey, correctionModeEnabled, grammarCorrectionEnabled].forEach(el => {
    el.onchange = saveAll;
});
