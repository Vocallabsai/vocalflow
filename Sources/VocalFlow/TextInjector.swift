import AppKit
import CoreGraphics

class TextInjector {
    func inject(text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedString = pasteboard.string(forType: .string)

        // Write transcript
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Wait for pasteboard write to propagate before simulating paste
        Thread.sleep(forTimeInterval: 0.05)

        // Simulate Cmd+V (physical 'V' key = 0x09, layout-independent)
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore original clipboard after paste has been processed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let saved = savedString {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }
}
