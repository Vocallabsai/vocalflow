import UIKit

/// The "mailbox" between the VocalFlow app (which records + transcribes) and the
/// keyboard (which inserts the text). This exists because iOS forbids audio
/// capture inside keyboard extensions — dictation happens in the container app
/// and the finished transcript is handed back through here.
///
/// Primary transport: a file in the App Group container (requires the App Groups
/// entitlement on both targets, and Full Access on the keyboard). Fallback when
/// the container isn't available (e.g. entitlement/signing hiccups during the
/// spike): the general pasteboard, marked with a custom type so the keyboard
/// only ever consumes items VocalFlow itself put there.
enum SharedTranscript {
    static let appGroupID = "group.vocallabsai.VocalFlow"
    private static let fileName = "pending_transcript.json"
    private static let pasteboardMarker = "ai.vocallabs.vocalflow.transcript"
    /// Transcripts older than this are stale — never inserted.
    private static let maxAge: TimeInterval = 180

    private struct Payload: Codable {
        let text: String
        let date: TimeInterval
    }

    private static var containerFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Which transport is live — surfaced in the spike UI for debugging.
    static var transport: String {
        containerFileURL != nil ? "app-group" : "pasteboard"
    }

    /// Called by the APP after dictation finishes.
    static func post(_ text: String) {
        let payload = Payload(text: text, date: Date().timeIntervalSince1970)
        if let url = containerFileURL, let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        } else {
            // Marked pasteboard item; also plain text so a manual paste works.
            UIPasteboard.general.items = [[
                pasteboardMarker: text.data(using: .utf8) ?? Data(),
                "public.utf8-plain-text": text,
            ]]
        }
    }

    /// Called by the KEYBOARD when it (re)appears. Returns the transcript at
    /// most once, and only if it's fresh.
    static func consume() -> String? {
        if let url = containerFileURL {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            try? FileManager.default.removeItem(at: url)
            guard Date().timeIntervalSince1970 - payload.date < maxAge else { return nil }
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        // Pasteboard fallback: only touch the pasteboard if our marker is present.
        let pasteboard = UIPasteboard.general
        guard pasteboard.contains(pasteboardTypes: [pasteboardMarker]) else { return nil }
        let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteboard.items = []
        return (text?.isEmpty == false) ? text : nil
    }
}
