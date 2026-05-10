import AppKit
import SwiftUI
import Combine

class MenuBarController {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var settingsWindow: NSWindow?
    private var overlayController: RecordingOverlayController?

    private var menu: NSMenu!
    private var errorMenuItem: NSMenuItem!
    private var historyMenuItem: NSMenuItem!
    private var historySeparator: NSMenuItem!

    private static let historyPreviewLimit = 60
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
        observeState()
        self.overlayController = RecordingOverlayController(appState: appState)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VocalFlow")
        button.image?.isTemplate = true

        let menu = NSMenu()

        // Hidden by default; populated when an error is being surfaced.
        errorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorMenuItem.isHidden = true
        menu.addItem(errorMenuItem)

        let errorSeparator = NSMenuItem.separator()
        errorSeparator.tag = 999
        errorSeparator.isHidden = true
        menu.addItem(errorSeparator)

        historyMenuItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        historyMenuItem.submenu = NSMenu(title: "Recent Transcripts")
        historyMenuItem.isHidden = true
        menu.addItem(historyMenuItem)

        historySeparator = NSMenuItem.separator()
        historySeparator.isHidden = true
        menu.addItem(historySeparator)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "Reset Permissions...",
            action: #selector(resetPermissions),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let quitItem = NSMenuItem(
            title: "Quit VocalFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.menu = menu
    }

    private func observeState() {
        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon()
                switch state {
                case .recording: self?.overlayController?.show()
                default:         self?.overlayController?.hide()
                }
            }
            .store(in: &cancellables)

        appState.$transientError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.updateErrorIndicator(message: message)
                self?.updateIcon()
            }
            .store(in: &cancellables)

        appState.$transcriptHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.rebuildHistorySubmenu(history)
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        // Active error trumps recording state for visibility.
        if appState.transientError != nil {
            applyIcon(symbol: "exclamationmark.triangle.fill")
            return
        }
        let symbolName: String
        switch appState.recordingState {
        case .idle:          symbolName = "mic"
        case .recording:     symbolName = "mic.fill"
        case .transcribing:  symbolName = "ellipsis.circle"
        case .error:         symbolName = "exclamationmark.triangle"
        }
        applyIcon(symbol: symbolName)
    }

    private func applyIcon(symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VocalFlow")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = appState.transientError ?? "VocalFlow"
    }

    private func updateErrorIndicator(message: String?) {
        guard let item = errorMenuItem else { return }
        if let message {
            item.title = "⚠ \(message)"
            item.isHidden = false
            menu.items.first(where: { $0.tag == 999 })?.isHidden = false
        } else {
            item.title = ""
            item.isHidden = true
            menu.items.first(where: { $0.tag == 999 })?.isHidden = true
        }
    }

    private func rebuildHistorySubmenu(_ history: [TranscriptEntry]) {
        guard let submenu = historyMenuItem.submenu else { return }
        submenu.removeAllItems()

        if history.isEmpty {
            historyMenuItem.isHidden = true
            historySeparator.isHidden = true
            return
        }
        historyMenuItem.isHidden = false
        historySeparator.isHidden = false

        for entry in history {
            let timeStr = Self.relativeTimeFormatter.localizedString(for: entry.timestamp, relativeTo: Date())
            let preview = Self.previewLine(entry.typed)

            let item = NSMenuItem(
                title: "\(preview)  ·  \(timeStr)",
                action: #selector(copyTranscript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.typed
            item.toolTip = entry.typed
            submenu.addItem(item)

            // Hold ⌥ to reveal & copy the raw Deepgram output for LLM-quality debugging.
            if entry.hasLLMProcessing {
                let rawPreview = Self.previewLine(entry.raw)
                let alt = NSMenuItem(
                    title: "Raw: \(rawPreview)  ·  \(timeStr)",
                    action: #selector(copyTranscript(_:)),
                    keyEquivalent: ""
                )
                alt.target = self
                alt.representedObject = entry.raw
                alt.toolTip = entry.raw
                alt.keyEquivalentModifierMask = [.option]
                alt.isAlternate = true
                submenu.addItem(alt)
            }
        }

        submenu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        submenu.addItem(clear)
    }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func clearHistory() {
        appState.clearTranscriptHistory()
    }

    private static func previewLine(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > historyPreviewLimit else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: historyPreviewLimit)
        return String(trimmed[..<idx]) + "…"
    }

    func showSettings() {
        openSettings()
    }

    @objc private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset VocalFlow Permissions?"
        alert.informativeText = """
        This clears Microphone and Accessibility grants for VocalFlow, then quits the app.

        Use this when the hotkey or text injection stops working after reinstalling — old grants from previous builds become invalid even if the toggle in System Settings still shows on.

        After quitting, re-launch VocalFlow and grant permissions again when prompted.
        """
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.vocalflow.app"
        for service in ["Accessibility", "Microphone"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            try? p.run()
            p.waitUntilExit()
        }

        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
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
