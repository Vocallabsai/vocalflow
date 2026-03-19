import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var appState: AppState?
    private var hotkeyManager: HotkeyManager?
    private var permissionsManager: PermissionsManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        self.appState = state
        self.menuBarController = MenuBarController(appState: state)
        self.permissionsManager = PermissionsManager()
        self.hotkeyManager = HotkeyManager(appState: state)

        permissionsManager?.requestPermissionsIfNeeded { [weak self] in
            self?.hotkeyManager?.startListening()
        }
    }
}
