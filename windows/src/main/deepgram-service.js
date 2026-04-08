const WebSocket = require('ws');
const fs = require('fs');
const fetch = require('node-fetch');

let ws = null;
let accumulatedTranscript = '';
let isWaitingForFinal = false;

function connect(apiKey, model, language, onResult) {
    accumulatedTranscript = '';
    isWaitingForFinal = false;

    const url = `wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000&channels=1&model=${model}&language=${language}&punctuate=true&interim_results=true`;
    
    ws = new WebSocket(url, {
        headers: {
            'Authorization': `Token ${apiKey}`
        }
    });

    ws.on('open', () => {
        console.log('Deepgram WebSocket opened.');
    });

    ws.on('message', (data) => {
        const response = JSON.parse(data.toString());
        const transcript = response.channel?.alternatives?.[0]?.transcript || '';

        if (response.is_final && transcript) {
            accumulatedTranscript += (accumulatedTranscript ? ' ' : '') + transcript;
        }

        if (isWaitingForFinal && response.is_final && response.speech_final) {
            onResult(accumulatedTranscript);
            disconnect();
        }
    });

    ws.on('error', (err) => {
        console.error('Deepgram WebSocket error:', err);
    });
}

function sendAudioChunk(chunk) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(chunk);
    }
}

function closeStream(onResult) {
    isWaitingForFinal = true;
    if (ws && ws.readyState === WebSocket.OPEN) {
        // Send empty frame to flush
        ws.send(Buffer.alloc(0));
    }
    
    // Safety timeout
    setTimeout(() => {
        if (isWaitingForFinal) {
            onResult(accumulatedTranscript);
            disconnect();
        }
    }, 3000);
}

function disconnect() {
    if (ws) {
        // Only close if it's not already closing or closed
        if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
            try {
                ws.close();
            } catch (e) {
                console.error('Error closing WebSocket:', e);
            }
        }
        ws = null;
    }
    isWaitingForFinal = false;
}

async function fetchModels(apiKey) {
  console.log('Fetching Deepgram models...');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000); // 30s timeout

  try {
    const response = await fetch('https://api.deepgram.com/v1/models', {
      headers: { 'Authorization': `Token ${apiKey}` },
      signal: controller.signal
    });
    
    if (!response.ok) {
        const errBody = await response.text();
        console.error(`Deepgram models API error (${response.status}):`, errBody);
        return [];
    }

    const data = await response.json();
    console.log(`Found ${data.stt ? data.stt.length : 0} total models`);
    
    const streamingModels = (data.stt || [])
      .filter(m => m.streaming)
      .map(m => ({
        canonicalName: m.canonical_name,
        displayName: m.name,
        languages: [...(m.languages || []), ...(m.canonical_name.includes('nova-2') || m.canonical_name.includes('nova-3') ? ['multi'] : [])]
      }))
      .sort((a, b) => a.canonicalName.localeCompare(b.canonicalName));
      
    console.log(`Returning ${streamingModels.length} streaming models`);
    return streamingModels;
  } catch (err) {
    if (err.name === 'AbortError') {
        console.error('Deepgram models fetch timed out.');
    } else {
        console.error('Failed to fetch Deepgram models:', err);
    }
    return [];
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = { connect, sendAudioChunk, closeStream, fetchModels };
