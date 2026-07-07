import SwiftUI

/// Minimal container app for the spike. A keyboard extension can't ship on its own —
/// it must be embedded in an app — so this exists mainly to host the extension and
/// tell the user how to enable it. (Later this grows into the real setup/keys/history UI.)
@main
struct VocalFlowApp: App {
    var body: some Scene {
        WindowGroup { SetupView() }
    }
}

struct SetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.purple)
                Text("VocalFlow").font(.largeTitle.bold())
            }
            Text("Voice dictation keyboard (spike build)").foregroundStyle(.secondary)

            GroupBox("Enable the keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Settings → General → Keyboard → Keyboards → Add New Keyboard… → VocalFlow", systemImage: "1.circle")
                    Label("Tap VocalFlow in that list → turn on “Allow Full Access”", systemImage: "2.circle")
                    Label("In any app, tap 🌐 to switch to the VocalFlow keyboard, then hold the mic", systemImage: "3.circle")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Text("Full Access is required so the keyboard can use the microphone and reach Deepgram.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}
