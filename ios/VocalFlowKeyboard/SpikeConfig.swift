import Foundation

/// SPIKE ONLY. Paste your Deepgram API key here *locally* to test the keyboard
/// extension in isolation — do NOT commit a real key.
///
/// This exists so the spike can prove the make-or-break question (mic + network
/// inside a keyboard extension) without first wiring up the App Group. Once the
/// spike works, replace this with a value read from the shared App Group that the
/// container app writes (see ios/README.md → "Next steps").
enum SpikeConfig {
    static let deepgramAPIKey = "PASTE_YOUR_DEEPGRAM_KEY_HERE"
}
