import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

// MARK: - Onboarding state

/// Drives the first-run setup: tracks the Deepgram key + Microphone + Accessibility
/// status live, requests each permission *in context* (from a button the user taps,
/// not a cold prompt), and fires `onReady` once Accessibility is granted so the app
/// can start listening for the hotkey.
final class OnboardingViewModel: ObservableObject {
    enum KeyStatus { case none, saved, verifying, verified, failed }

    @Published var keyInput: String
    @Published var keyStatus: KeyStatus
    @Published var micGranted = false
    @Published var axGranted = false

    /// Fired when a permission newly flips to granted — the controller uses it to
    /// bring the onboarding window back to the front (the user was just in System
    /// Settings, and this is an accessory app with no Dock icon to click back to).
    var onGrantDetected: (() -> Void)?

    private let appState: AppState
    private let onReady: () -> Void
    private var readyFired = false
    private var pollTimer: Timer?

    init(appState: AppState, onReady: @escaping () -> Void) {
        self.appState = appState
        self.onReady = onReady
        self.keyInput = appState.deepgramAPIKey
        self.keyStatus = appState.deepgramAPIKey.isEmpty ? .none : .saved
        refresh()
    }

    var allDone: Bool { micGranted && axGranted && (keyStatus == .saved || keyStatus == .verified) }

    /// Poll while the window is open so ✓s flip live when the user grants a
    /// permission in System Settings (which sends no callback to us).
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    func refresh() {
        let wasMic = micGranted, wasAx = axGranted
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        if !appState.deepgramAPIKey.isEmpty, keyStatus == .none { keyStatus = .saved }
        if (!wasMic && micGranted) || (!wasAx && axGranted) { onGrantDetected?() }
        if axGranted { fireReady() }
    }

    private func fireReady() {
        guard !readyFired else { return }
        readyFired = true
        onReady()
    }

    /// Called by the controller when the window is dismissed — make sure listening
    /// starts even if the user finished setup in a way the poll didn't catch.
    func finish() { fireReady() }

    func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        default: // denied/restricted — the prompt won't reappear, so send them to Settings
            NSWorkspace.shared.open(SystemPrefsURL.microphone)
        }
    }

    func requestAccessibility() {
        // Prompt (shows the system "grant Accessibility" dialog if there's no entry yet)…
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
        // …and open the pane directly so it's one click either way.
        NSWorkspace.shared.open(SystemPrefsURL.accessibility)
        startPolling()
    }

    @MainActor
    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        appState.keychainService.store(key: "deepgram_api_key", value: key)
        appState.deepgramAPIKey = key
        keyStatus = .verifying
        Task { @MainActor in
            do {
                let models = try await appState.deepgramService.fetchModels(apiKey: key)
                if models.isEmpty { keyStatus = .failed }
                else { appState.availableModels = models; keyStatus = .verified }
            } catch {
                keyStatus = .failed   // stored anyway; they can re-check in Settings
            }
        }
    }
}

// MARK: - View

private struct StepRow<Trailing: View>: View {
    let index: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.vlAccent : Color.vlAccent.opacity(0.15))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(index)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.vlAccent)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.medium).foregroundStyle(Color.vlTextPrimary)
                Text(detail).font(.caption).foregroundStyle(Color.vlTextSecondary)
                trailing().padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var showKey = false
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.title2).foregroundStyle(Color.vlAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to VocalFlow").font(.title2.weight(.semibold)).foregroundStyle(Color.vlTextPrimary)
                    Text("Two quick steps and you're dictating into any app.").font(.callout).foregroundStyle(Color.vlTextSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                // 1 — Deepgram key
                StepRow(index: 1, done: vm.keyStatus == .saved || vm.keyStatus == .verified,
                        title: "Add your Deepgram API key",
                        detail: "Powers transcription — free tier available.") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Group {
                                if showKey { TextField("dg_…", text: $vm.keyInput) }
                                else { SecureField("dg_…", text: $vm.keyInput) }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            Button(showKey ? "Hide" : "Show") { showKey.toggle() }.buttonStyle(VLSecondaryButtonStyle())
                            Button("Save") { vm.saveKey() }
                                .buttonStyle(VLAccentButtonStyle())
                                .disabled(vm.keyInput.trimmingCharacters(in: .whitespaces).isEmpty || vm.keyStatus == .verifying)
                        }
                        HStack(spacing: 10) {
                            switch vm.keyStatus {
                            case .verifying: Text("Verifying…").font(.caption).foregroundStyle(Color.vlTextSecondary)
                            case .verified:  Text("Verified ✓").font(.caption).foregroundStyle(Color.vlSuccess)
                            case .saved:     Text("Saved ✓").font(.caption).foregroundStyle(Color.vlSuccess)
                            case .failed:    Text("Saved — couldn't verify (check the key)").font(.caption).foregroundStyle(Color.vlError)
                            case .none:      EmptyView()
                            }
                            Link("Get a free key →", destination: URL(staticString: "https://console.deepgram.com/signup")).font(.caption)
                        }
                    }
                }

                Divider().overlay(Color.vlCardBorder)

                // 2 — Microphone
                StepRow(index: 2, done: vm.micGranted,
                        title: "Allow Microphone",
                        detail: "So VocalFlow can hear you.") {
                    if vm.micGranted { Text("Granted ✓").font(.caption).foregroundStyle(Color.vlSuccess) }
                    else { Button("Allow Microphone") { vm.requestMic() }.buttonStyle(VLSecondaryButtonStyle()) }
                }

                Divider().overlay(Color.vlCardBorder)

                // 3 — Accessibility
                StepRow(index: 3, done: vm.axGranted,
                        title: "Allow Accessibility",
                        detail: "Needed for the global hotkey and to type text into other apps.") {
                    if vm.axGranted { Text("Granted ✓").font(.caption).foregroundStyle(Color.vlSuccess) }
                    else { Button("Open Accessibility Settings") { vm.requestAccessibility() }.buttonStyle(VLSecondaryButtonStyle()) }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.vlCardBg))

            // Where the app lives
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.caption.weight(.bold)).foregroundStyle(Color.vlAccent)
                Text("VocalFlow lives in your menu bar — click the **mic icon** up there to open Settings anytime.")
                    .font(.caption).foregroundStyle(Color.vlTextSecondary)
            }

            HStack {
                Button("Open Settings") { onOpenSettings() }.buttonStyle(VLSecondaryButtonStyle())
                Spacer()
                Button(vm.allDone ? "Start dictating" : "Finish later") { onDismiss() }
                    .buttonStyle(VLAccentButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Color.vlWindowBg)
        .tint(.vlAccent)
        .preferredColorScheme(.dark)
        .onAppear { vm.startPolling(); vm.refresh() }
        .onDisappear { vm.stopPolling() }
    }
}

// MARK: - Controller

class WelcomeWindowController {
    private var window: NSWindow?
    private let appState: AppState
    private let onOpenSettings: () -> Void
    private let onReady: () -> Void
    private var vm: OnboardingViewModel?

    init(appState: AppState, onOpenSettings: @escaping () -> Void, onReady: @escaping () -> Void) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        self.onReady = onReady
    }

    /// Show the guided setup whenever the app isn't usable yet — i.e. there's no
    /// Deepgram key saved. It reappears on each launch until setup is complete;
    /// "Finish later" only dismisses it for the current session. Once a key is
    /// saved it never shows again (so configured/existing users never see it).
    static func shouldShow(deepgramKey: String) -> Bool {
        return deepgramKey.isEmpty
    }

    func show() {
        if window == nil {
            let vm = OnboardingViewModel(appState: appState, onReady: onReady)
            self.vm = vm
            vm.onGrantDetected = { [weak self] in self?.refocus() }
            let view = OnboardingView(
                vm: vm,
                onOpenSettings: { [weak self] in self?.onOpenSettings() },
                onDismiss: { [weak self] in self?.dismiss() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: view)
            window.title = "Welcome to VocalFlow"
            window.isReleasedWhenClosed = false
            // Blend the titlebar into the dark window, matching Settings.
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Color.vlWindowBg)
            window.isMovableByWindowBackground = true
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring the onboarding window back to the front (e.g. after the user granted a
    /// permission in System Settings) so they return to it, not a lost window.
    private func refocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        vm?.finish()
        vm?.stopPolling()
        window?.orderOut(nil)
    }
}
