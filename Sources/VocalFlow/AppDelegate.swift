import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var appState: AppState?
    private var hotkeyManager: HotkeyManager?
    private var permissionsManager: PermissionsManager?
    private var welcomeWindowController: WelcomeWindowController?
    private var updaterManager: UpdaterManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        self.appState = state
        // Start Sparkle early so its scheduled background check can run.
        let updater = UpdaterManager()
        self.updaterManager = updater
        let menuBar = MenuBarController(appState: state, updater: updater)
        self.menuBarController = menuBar
        self.permissionsManager = PermissionsManager()
        self.hotkeyManager = HotkeyManager(appState: state)

        let startListening: () -> Void = { [weak self] in
            guard let self else { return }
            self.hotkeyManager?.startListening()
        }

        if WelcomeWindowController.shouldShow(deepgramKey: state.deepgramAPIKey) {
            // First run: the guided onboarding window requests Microphone + Accessibility
            // in context (not as cold prompts) and starts the hotkey once Accessibility is
            // granted — so a brand-new user sees a clear setup screen first, not bare alerts.
            let welcome = WelcomeWindowController(
                appState: state,
                onOpenSettings: { [weak menuBar] in menuBar?.showSettings() },
                onReady: startListening
            )
            self.welcomeWindowController = welcome
            DispatchQueue.main.async { welcome.show() }
        } else {
            // Returning user: quiet permission check, then start listening.
            permissionsManager?.requestPermissionsIfNeeded(completion: startListening)
        }
    }
}
