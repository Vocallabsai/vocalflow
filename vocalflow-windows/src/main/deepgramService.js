const WebSocket = require('ws');

class DeepgramService {
  constructor({ apiKey, model, language, onTranscript, onError, onOpen, onClose }) {
    this.apiKey = apiKey;
    this.model = model || 'nova-2';
    this.language = language || 'en';
    this.onTranscript = onTranscript;
    this.onError = onError;
    this.onOpen = onOpen;
    this.onClose = onClose;
    
    this.ws = null;
  }

  connect() {
    const params = new URLSearchParams({
      model: this.model,
      language: this.language,
      encoding: 'linear16',
      sample_rate: '16000',
      channels: '1',
      interim_results: 'true',
      punctuate: 'true',
      smart_format: 'true'
    });

    const url = `wss://api.deepgram.com/v1/listen?${params.toString()}`;

    this.ws = new WebSocket(url, {
      headers: {
        Authorization: `Token ${this.apiKey}`
      }
    });

    this.ws.on('open', () => {
      if (this.onOpen) this.onOpen();
    });

    this.ws.on('message', (data) => {
      try {
        const parsed = JSON.parse(data.toString());
        
        if (parsed.is_final) {
          const channel = parsed.channel;
          if (channel && channel.alternatives && channel.alternatives.length > 0) {
            const transcript = channel.alternatives[0].transcript;
            // Only fire if there's actual spoken text
            if (transcript && transcript.trim().length > 0) {
              if (this.onTranscript) this.onTranscript(transcript);
            }
          }
        }
      } catch (err) {
        if (this.onError) this.onError(err);
      }
    });

    this.ws.on('error', (err) => {
      if (this.onError) this.onError(err);
    });

    this.ws.on('close', () => {
      if (this.onClose) this.onClose();
    });
  }

  sendAudio(buffer) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(buffer);
    }
  }

  close() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      // Send Deepgram the CloseStream event to elegantly terminate the recording session
      this.ws.send(JSON.stringify({ type: "CloseStream" }));
      this.ws.close();
    }
    this.ws = null;
  }
}

module.exports = DeepgramService;
