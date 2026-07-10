import Foundation

/// User settings, shared through the App Group so both the app and the
/// keyboard can read them (falls back to standard defaults when the group
/// isn't provisioned — e.g. signing hiccups on a personal team).
///
/// Spike-tier storage: the shipping app should graduate the API key to the
/// Keychain (shared access group), like the macOS app does.
enum AppSettings {
    private static let deepgramKeyKey = "deepgram_api_key"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedTranscript.appGroupID) ?? .standard
    }

    /// The user's Deepgram API key. Empty string = not configured.
    static var deepgramKey: String {
        get { defaults.string(forKey: deepgramKeyKey) ?? "" }
        set { defaults.set(newValue, forKey: deepgramKeyKey) }
    }
}
