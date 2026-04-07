let mediaRecorder;
let audioStream;

// Setup Translateration combinations dynamically
const transliterationPairs = [
    "Hinglish → English", "Tanglish → English", "Spanglish → English",
    "Franglais → English", "Denglish → English", "Chinglish → English",
    "Konglish → English", "Janglish → English", "Portuñol → English",
    "Arabizi → English", "Taglish → English", "Russlish → English",
    "Itangliano → English", "Greeklish → English", "Benglish → English",
    "Telunglish → English"
];

// Execute API Fetch for Deepgram Balance
async function refreshDeepgramBalance() {
    const key = document.getElementById('deepgram-key').value;
    const label = document.getElementById('deepgram-balance-label');
    if(!key) {
        label.innerText = 'Key missing';
        return;
    }

    label.innerText = 'Fetching...';
    label.className = 'status-text text-muted';
    
    try {
        const balance = await window.vocalflow.fetchDeepgramBalance(key);
        if (balance !== null && balance !== undefined) {
            label.innerText = `$${Number(balance).toFixed(4)} USD`;
            label.className = 'status-text text-green';
        } else {
            label.innerText = 'Error loading balance';
            label.className = 'status-text text-red';
        }
    } catch (e) {
        label.innerText = 'Error loading balance';
        label.className = 'status-text text-red';
    }
}

// Execute API Fetch for Groq Status
async function refreshGroqStatus() {
    const key = document.getElementById('groq-key').value;
    const label = document.getElementById('groq-status-label');
    if(!key) {
        label.innerText = 'Key missing';
        return;
    }

    label.innerText = 'Checking...';
    label.className = 'status-text text-muted';
    
    try {
        const isValid = await window.vocalflow.fetchGroqStatus(key);
        if (isValid) {
            label.innerText = '✓ Key valid';
            label.className = 'status-text text-green';
        } else {
            label.innerText = '✗ Invalid key';
            label.className = 'status-text text-red';
        }
    } catch (e) {
        label.innerText = '✗ Error checking API';
        label.className = 'status-text text-red';
    }
}

// Deepgram model fetcher
async function fetchDeepgramModelsList() {
    const key = document.getElementById('deepgram-key').value;
    if (!key) return;
    const select = document.getElementById('deepgram-model');
    const prevVal = select.value;
    select.innerHTML = '<option value="">Fetching...</option>';
    
    try {
        const models = await window.vocalflow.fetchDeepgramModels(key);
        select.innerHTML = '';
        if (models && models.length > 0) {
            models.forEach(m => {
                const opt = document.createElement('option');
                opt.value = m;
                opt.innerText = m;
                select.appendChild(opt);
            });
            select.value = prevVal || models[0];
        } else {
            select.innerHTML = `<option value="nova-3">nova-3</option>`;
        }
    } catch (e) {
        select.innerHTML = `<option value="${prevVal || 'nova-3'}">${prevVal || 'nova-3'}</option>`;
    }
}

// Groq model fetcher
async function fetchGroqModelsList() {
    const key = document.getElementById('groq-key').value;
    if (!key) return;
    const select = document.getElementById('groq-model');
    const prevVal = select.value;
    select.innerHTML = '<option value="">Fetching...</option>';
    
    try {
        const models = await window.vocalflow.fetchGroqModels(key);
        select.innerHTML = '';
        if (models && models.length > 0) {
            models.forEach(m => {
                const opt = document.createElement('option');
                opt.value = m;
                opt.innerText = m;
                select.appendChild(opt);
            });
            select.value = prevVal || models[0];
        } else {
            select.innerHTML = `<option value="llama3-8b-8192">llama3-8b-8192</option>`;
        }
    } catch (e) {
        select.innerHTML = `<option value="${prevVal || 'llama3-8b-8192'}">${prevVal || 'llama3-8b-8192'}</option>`;
    }
}

// Master Settings Save Routine
async function saveAllSettings() {
    const settings = {
        DEEPGRAM_API_KEY: document.getElementById('deepgram-key').value,
        DEEPGRAM_MODEL: document.getElementById('deepgram-model').value,
        DEEPGRAM_LANGUAGE: document.getElementById('deepgram-language').value,
        
        GROQ_ENABLE: document.getElementById('groq-enable').checked,
        GROQ_API_KEY: document.getElementById('groq-key').value,
        GROQ_MODEL: document.getElementById('groq-model').value,
        GROQ_SPELLING_CORRECTION: document.getElementById('groq-spelling').checked,
        GROQ_GRAMMAR_CORRECTION: document.getElementById('groq-grammar').checked,
        GROQ_TRANSLITERATION: document.getElementById('groq-transliteration').checked,
        GROQ_TRANSLATION: document.getElementById('groq-translation').checked,
        GROQ_TRANSLITERATION_PAIR: document.getElementById('groq-transliteration-pair').value,
        GROQ_TRANSLATION_TARGET: document.getElementById('groq-translation-target').value,
        
        HOTKEY: document.getElementById('hotkey').value,
    };
    
    const success = await window.vocalflow.saveSettings(settings);
    if (success) {
        const btn = document.getElementById('save-all-btn');
        const originalText = btn.innerText;
        btn.innerText = 'Saved!';
        btn.style.background = 'var(--success)';
        setTimeout(() => {
            btn.innerText = originalText;
            btn.style.background = 'var(--accent)';
        }, 2000);
    }
}

function handleUIInteractivity() {
    // Conditionals for UI elements
    const updateVisibility = () => {
        document.getElementById('transliteration-box').style.display = document.getElementById('groq-transliteration').checked ? 'block' : 'none';
        document.getElementById('translation-box').style.display = document.getElementById('groq-translation').checked ? 'block' : 'none';
        
        const isGroqEnabled = document.getElementById('groq-enable').checked;
        document.getElementById('groq-settings-container').style.opacity = isGroqEnabled ? '1' : '0.4';
        document.getElementById('groq-settings-container').style.pointerEvents = isGroqEnabled ? 'auto' : 'none';
    };

    ['groq-transliteration', 'groq-translation', 'groq-enable'].forEach(id => {
        document.getElementById(id).addEventListener('change', updateVisibility);
    });

    return updateVisibility;
}

// Initial Boot Sequence
window.addEventListener('DOMContentLoaded', async () => {
    // Scaffold UI dynamics
    const pairSelect = document.getElementById('groq-transliteration-pair');
    transliterationPairs.forEach(p => {
        const opt = document.createElement('option');
        opt.value = p; opt.innerText = p;
        pairSelect.appendChild(opt);
    });

    const triggerUIVisibility = handleUIInteractivity();

    // Map Interactivity
    document.getElementById('deepgram-refresh').addEventListener('click', refreshDeepgramBalance);
    document.getElementById('groq-refresh').addEventListener('click', refreshGroqStatus);
    document.getElementById('deepgram-fetch-models').addEventListener('click', fetchDeepgramModelsList);
    document.getElementById('groq-fetch-models').addEventListener('click', fetchGroqModelsList);
    document.getElementById('save-all-btn').addEventListener('click', saveAllSettings);
    
    // Explicit Save links
    document.getElementById('deepgram-save-key').addEventListener('click', saveAllSettings);
    document.getElementById('groq-save-key').addEventListener('click', saveAllSettings);

    document.getElementById('quit-btn').addEventListener('click', () => {
        window.close(); // Triggers app closure naturally through renderer window control
    });

    // Populate Settings Payload directly from FileSystem via IPC
    const settings = await window.vocalflow.getSettings();
    if (settings) {
        document.getElementById('deepgram-key').value = settings.DEEPGRAM_API_KEY || '';
        document.getElementById('deepgram-model').innerHTML = `<option value="${settings.DEEPGRAM_MODEL || 'nova-3'}">${settings.DEEPGRAM_MODEL || 'nova-3'}</option>`;
        document.getElementById('deepgram-language').value = settings.DEEPGRAM_LANGUAGE || 'en';
        
        document.getElementById('groq-enable').checked = settings.GROQ_ENABLE || false;
        document.getElementById('groq-key').value = settings.GROQ_API_KEY || '';
        document.getElementById('groq-model').innerHTML = `<option value="${settings.GROQ_MODEL || 'llama3-8b-8192'}">${settings.GROQ_MODEL || 'llama3-8b-8192'}</option>`;
        
        document.getElementById('groq-spelling').checked = settings.GROQ_SPELLING_CORRECTION || false;
        document.getElementById('groq-grammar').checked = settings.GROQ_GRAMMAR_CORRECTION || false;
        document.getElementById('groq-transliteration').checked = settings.GROQ_TRANSLITERATION || false;
        document.getElementById('groq-translation').checked = settings.GROQ_TRANSLATION || false;
        
        if (settings.GROQ_TRANSLITERATION_PAIR) pairSelect.value = settings.GROQ_TRANSLITERATION_PAIR;
        document.getElementById('groq-translation-target').value = settings.GROQ_TRANSLATION_TARGET || '';
        
        document.getElementById('hotkey').value = settings.HOTKEY || 'RIGHT ALT';
        triggerUIVisibility();
    }

    // Auto-fetch Status Metrics IF Keys present
    if (document.getElementById('deepgram-key').value) refreshDeepgramBalance();
    if (document.getElementById('groq-key').value) refreshGroqStatus();
});

// IPC Driven Media Control Hooks (From the Main Desktop Context)
window.vocalflow.onStartRecording(async () => {
    try {
        audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        mediaRecorder = new MediaRecorder(audioStream);
        
        mediaRecorder.ondataavailable = async (event) => {
            if (event.data && event.data.size > 0) {
                // Convert payload Blob -> ArrayBuffer strictly
                const buffer = await event.data.arrayBuffer();
                window.vocalflow.sendAudioChunk(buffer);
            }
        };

        // Standard latency for realtime transcription
        mediaRecorder.start(250); 
    } catch (err) {
        console.error("Microphone Capture Denied/Failed:", err);
    }
});

window.vocalflow.onStopRecording(() => {
    if (mediaRecorder && mediaRecorder.state !== 'inactive') {
        mediaRecorder.stop();
    }
    // Shut off Microphone Hardware Signal entirely
    if (audioStream) {
        audioStream.getTracks().forEach(track => track.stop());
    }
});
