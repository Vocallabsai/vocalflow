import AppKit
import SwiftUI

private let welcomeShownKey = "welcome_shown_v1"

private struct WelcomeStep: View {
    let number: String
    let title: String
    let detail: String
    let links: [(label: String, url: URL)]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    ForEach(links, id: \.label) { link in
                        Link(link.label, destination: link.url)
                            .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct WelcomeView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("Welcome to VocalFlow")
                        .font(.title2.weight(.semibold))
                }
                Text("Hold a hotkey, speak, and your words are typed into any text field.")
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                WelcomeStep(
                    number: "1",
                    title: "Add a Deepgram API key",
                    detail: "Required for transcription. Free tier available.",
                    links: [("Get Deepgram key →", URL(staticString: "https://console.deepgram.com/signup"))]
                )

                WelcomeStep(
                    number: "2",
                    title: "Optional: add an LLM key",
                    detail: "Enables spelling and grammar fixes, code-mix input, and translation.",
                    links: [
                        ("Groq →",       LLMProvider.groq.signupURL),
                        ("OpenRouter →", LLMProvider.openRouter.signupURL),
                    ]
                )

                WelcomeStep(
                    number: "3",
                    title: "Paste keys into Settings",
                    detail: "Find Settings any time via the mic icon in the menu bar.",
                    links: []
                )
            }

            HStack {
                Spacer()
                Button("Maybe later", action: onDismiss)
                Button("Open Settings", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

class WelcomeWindowController {
    private var window: NSWindow?
    private let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    static func shouldShow(deepgramKey: String) -> Bool {
        if UserDefaults.standard.bool(forKey: welcomeShownKey) { return false }
        // Don't pester existing users who already configured the app on a prior version.
        return deepgramKey.isEmpty
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: welcomeShownKey)
    }

    func show() {
        if window == nil {
            let view = WelcomeView(
                onOpenSettings: { [weak self] in
                    self?.close()
                    self?.onOpenSettings()
                },
                onDismiss: { [weak self] in self?.close() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: view)
            window.title = "Welcome to VocalFlow"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.markShown()
    }

    private func close() {
        window?.orderOut(nil)
    }
}
