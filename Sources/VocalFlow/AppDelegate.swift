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

        permissionsManager?.requestPermissionsIfNeeded { [weak self] in
            self?.hotkeyManager?.startListening()
        }

        if WelcomeWindowController.shouldShow(deepgramKey: state.deepgramAPIKey) {
            let welcome = WelcomeWindowController(
                onOpenSettings: { [weak menuBar] in menuBar?.showSettings() }
            )
            self.welcomeWindowController = welcome
            DispatchQueue.main.async { welcome.show() }
        }
    }
}
