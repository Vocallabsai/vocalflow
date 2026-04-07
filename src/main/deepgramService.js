const WebSocket = require('ws');

class DeepgramService {
    constructor() {
        this.socket = null;
        this.onTranscript = null;
        this.pingInterval = null;
    }

    connect(settings) {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            return;
        }

        const apiKey = settings.DEEPGRAM_API_KEY || process.env.DEEPGRAM_API_KEY;
        if (!apiKey) {
            console.error('[DeepgramService] No API key provided, skipping STT.');
            return;
        }

        const model = settings.DEEPGRAM_MODEL || 'nova-3';
        const language = settings.DEEPGRAM_LANGUAGE || 'en';

        // Do not force sample_rate/format since electron provides MediaRecorder generic WEBM buffers
        const url = `wss://api.deepgram.com/v1/listen?model=${model}&language=${language}`;

        this.socket = new WebSocket(url, {
            headers: {
                Authorization: `Token ${apiKey}`
            }
        });

        this.socket.on('open', () => {
            console.log('[DeepgramService] Connected & active');
            this.keepAlive();
        });

        this.socket.on('message', (data) => {
            try {
                const response = JSON.parse(data);
                // Listen dynamically for finalized results / alternatices
                if (response.channel && response.channel.alternatives && response.channel.alternatives[0]) {
                    const transcript = response.channel.alternatives[0].transcript;
                    if (transcript && this.onTranscript && response.is_final) {
                        this.onTranscript(transcript);
                    }
                }
            } catch (err) {
                // Buffer parsing issue, safe ignore
            }
        });

        this.socket.on('close', () => {
            console.log('[DeepgramService] Connection sealed');
            this.clearKeepAlive();
            this.socket = null;
        });

        this.socket.on('error', (err) => {
            console.error('[DeepgramService] Stream error:', err);
        });
    }

    sendAudio(buffer) {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            this.socket.send(buffer);
        }
    }

    close() {
        if (this.socket) {
            // Provide termination payload
            if (this.socket.readyState === WebSocket.OPEN) {
                this.socket.send(new Uint8Array(0));
            }
            setTimeout(() => {
                if (this.socket) this.socket.close();
            }, 500); 
        }
    }

    keepAlive() {
        this.clearKeepAlive();
        this.pingInterval = setInterval(() => {
            if (this.socket && this.socket.readyState === WebSocket.OPEN) {
                this.socket.send(JSON.stringify({ type: 'KeepAlive' }));
            }
        }, 10000);
    }

    clearKeepAlive() {
        if (this.pingInterval) {
            clearInterval(this.pingInterval);
            this.pingInterval = null;
        }
    }
}

module.exports = DeepgramService;
