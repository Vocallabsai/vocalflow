import AppKit
import SwiftUI
import Combine

class MenuBarController {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var settingsWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
        observeState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VocalFlow")
        button.image?.isTemplate = true

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VocalFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func observeState() {
        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: RecordingState) {
        let symbolName: String
        switch state {
        case .idle:          symbolName = "mic"
        case .recording:     symbolName = "mic.fill"
        case .transcribing:  symbolName = "ellipsis.circle"
        case .error:         symbolName = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VocalFlow")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: contentView)
            window.title = "VocalFlow Settings"
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
