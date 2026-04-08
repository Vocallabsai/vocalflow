# VocalFlow for Windows

A lightweight Windows system tray app that lets you dictate into any text field using a hold-to-record hotkey (Default: Right Alt).

## Features

- **Hold-to-record** — Configurable hotkey: Right Alt, Left Alt, Right Ctrl, etc.
- **Real-time ASR** — Powered by Deepgram's WebSocket API.
- **Post-processing** — Optional grammar and spelling correction via Groq LLM.
- **Code-Mix & Translation** — Support for 16+ language styles (Hinglish, Spanglish, etc.).
- **Global Text Injection** — Works in any app via simulated clipboard paste.
- **Balance Tracking** — View your Deepgram balance directly in the settings.

## Prerequisites

1. **Node.js** (v16 or later)
2. **SoX** or **FFmpeg** — Required for microphone capture.
   - Install SoX: `choco install sox` (via Chocolatey) or download from [SourceForge](https://sourceforge.net/projects/sox/).
   - Add SoX to your system PATH.

## Installation & Setup

1. **Clone the project** and navigate to the `windows` directory.
2. **Install dependencies**:
   ```bash
   npm install
   ```
3. **Configure API Keys**:
   - Open `config.json` and add your Deepgram and Groq API keys.
   - Alternatively, you can enter them in the app's Settings UI.
4. **Run the app**:
   ```bash
   npm start
   ```

## Usage

1. Look for the **VocalFlow icon** in your system tray (bottom right).
2. Right-click the icon and select **Settings** to configure models and languages.
3. Click **Save & Fetch Models** to see your balance and available models.
4. **Hold Right Alt** (or your configured hotkey), speak, and release.
5. The transcribed text will be automatically pasted at your cursor.

## Project Structure

- `src/main/`: Electron main process (hotkeys, audio, API services).
- `src/renderer/`: Settings UI (HTML/CSS/JS).
- `config.json`: Hardcoded API keys (for testing).

## Note on Icons

Placeholder icons are expected in the `resources/` directory:
- `icon.ico`: Default tray icon.
- `icon-recording.ico`: Tray icon during recording.

## License

MIT
