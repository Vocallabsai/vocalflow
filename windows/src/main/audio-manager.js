const { spawn } = require('child_process');
const path = require('path');

let recordingProcess = null;

function startCapture(onAudioData) {
    // FFmpeg arguments for your specific AMD Microphone Array
    const args = [
        '-f', 'dshow',                                 // Use DirectShow
        '-i', 'audio=Microphone Array (AMD Audio Device)', // Your specific device
        '-ar', '16000',                                // 16k sample rate
        '-ac', '1',                                    // Mono
        '-f', 's16le',                                 // PCM 16-bit little-endian
        '-'                                            // Output to stdout
    ];

    recordingProcess = spawn('ffmpeg', args);

    recordingProcess.stdout.on('data', (chunk) => {
        onAudioData(chunk);
    });

    recordingProcess.on('error', (err) => {
        console.error('Recording process error:', err);
    });

    recordingProcess.stderr.on('data', (data) => {
        const output = data.toString();
        // Only log actual errors or warnings to keep the terminal reasonably clean
        if (output.toLowerCase().includes('fail') || output.toLowerCase().includes('error') || output.toLowerCase().includes('invalid')) {
            console.error(`FFmpeg Log: ${output}`);
        }
    });
}

function stopCapture() {
    if (recordingProcess) {
        const { execSync } = require('child_process');
        try {
            // Synchronously force-kill the process tree to be 100% sure the mic is released
            execSync(`taskkill /pid ${recordingProcess.pid} /T /F`, { stdio: 'ignore' });
        } catch (err) {
            // Process might already be dead
        }
        recordingProcess = null;
    }
}

module.exports = { startCapture, stopCapture };
