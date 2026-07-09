import UIKit

// ============================================================================
// The keyboard ↔ app bridge for "background dictation" (Wispr-style UX):
// the keyboard opens the app, the app starts recording and immediately
// bounces back; recording continues in the BACKGROUND while the keyboard
// shows live state and remote-controls it (stop/cancel). Cross-process
// signalling is Darwin notifications; payloads travel through small JSON
// files in the App Group container.
// ============================================================================

enum DictationPhase: String, Codable {
    case idle, recording, transcribing, done, failed
}

struct DictationState: Codable {
    var phase: DictationPhase
    var partial: String = ""
    var message: String = ""
    var date: TimeInterval
}

enum SharedTranscript {
    static let appGroupID = "group.vocallabsai.VocalFlow"

    /// Darwin notification names (payload-less cross-process pings).
    static let stateDidChangeNote = "ai.vocallabs.vocalflow.state"
    static let commandNote = "ai.vocallabs.vocalflow.command"

    private static let transcriptFile = "pending_transcript.json"
    private static let stateFile = "dictation_state.json"
    private static let commandFile = "dictation_command.json"
    private static let pasteboardMarker = "ai.vocallabs.vocalflow.transcript"
    /// Anything older than this is stale — never inserted / never trusted.
    private static let maxAge: TimeInterval = 180

    private struct Payload: Codable {
        let text: String
        let date: TimeInterval
    }

    private static func fileURL(_ name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    /// Which transport is live — surfaced in the spike UI for debugging.
    static var transport: String {
        fileURL(transcriptFile) != nil ? "app-group" : "pasteboard"
    }

    // MARK: - Final transcript mailbox (consume-once)

    /// Called by the APP when dictation finishes.
    static func post(_ text: String) {
        let payload = Payload(text: text, date: Date().timeIntervalSince1970)
        if let url = fileURL(transcriptFile), let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        } else {
            // Marked pasteboard item; also plain text so a manual paste works.
            UIPasteboard.general.items = [[
                pasteboardMarker: text.data(using: .utf8) ?? Data(),
                "public.utf8-plain-text": text,
            ]]
        }
    }

    /// Called by the KEYBOARD. Returns the transcript at most once, only if fresh.
    static func consume() -> String? {
        if let url = fileURL(transcriptFile) {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            try? FileManager.default.removeItem(at: url)
            guard Date().timeIntervalSince1970 - payload.date < maxAge else { return nil }
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let pasteboard = UIPasteboard.general
        guard pasteboard.contains(pasteboardTypes: [pasteboardMarker]) else { return nil }
        let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteboard.items = []
        return (text?.isEmpty == false) ? text : nil
    }

    // MARK: - Live state (app → keyboard)

    static func writeState(_ phase: DictationPhase, partial: String = "", message: String = "") {
        guard let url = fileURL(stateFile) else { return }
        let state = DictationState(phase: phase, partial: partial, message: message,
                                   date: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
        DarwinNote.post(stateDidChangeNote)
    }

    static func readState() -> DictationState? {
        guard let url = fileURL(stateFile),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(DictationState.self, from: data) else { return nil }
        return state
    }

    static func clearState() {
        if let url = fileURL(stateFile) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Commands (keyboard → app): "stop" | "cancel"

    static func sendCommand(_ command: String) {
        guard let url = fileURL(commandFile) else { return }
        let payload = Payload(text: command, date: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
        DarwinNote.post(commandNote)
    }

    static func takeCommand() -> String? {
        guard let url = fileURL(commandFile),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard Date().timeIntervalSince1970 - payload.date < 30 else { return nil }
        return payload.text
    }
}

// MARK: - Darwin notification helpers

enum DarwinNote {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }
}

/// Observes one Darwin notification for the lifetime of the instance.
/// Callback is delivered on the main queue.
final class DarwinObserver {
    private let callback: () -> Void

    init(name: String, callback: @escaping () -> Void) {
        self.callback = callback
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { instance.callback() }
        }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
