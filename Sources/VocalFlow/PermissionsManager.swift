import AppKit
import AVFoundation
import ApplicationServices

class PermissionsManager {
    func requestPermissionsIfNeeded(completion: @escaping () -> Void) {
        checkMicrophonePermission { [weak self] micGranted in
            guard micGranted else {
                self?.showAlert(
                    title: "Microphone Access Required",
                    message: "VocalFlow needs microphone access to record your speech.\n\nGo to System Settings → Privacy & Security → Microphone and enable VocalFlow.",
                    actionTitle: "Open System Settings",
                    action: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                )
                return
            }

            self?.checkAccessibilityPermission { [weak self] axGranted in
                guard axGranted else {
                    self?.showAlert(
                        title: "Accessibility Access Required",
                        message: "VocalFlow needs Accessibility access to detect the hotkey and inject text.\n\nGo to System Settings → Privacy & Security → Accessibility and add VocalFlow.",
                        actionTitle: "Open System Settings",
                        action: {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                    )
                    // Poll and proceed once granted
                    self?.pollForAccessibility(attempts: 60, completion: completion)
                    return
                }
                completion()
            }
        }
    }

    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func checkAccessibilityPermission(completion: @escaping (Bool) -> Void) {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        completion(trusted)
    }

    private func pollForAccessibility(attempts: Int, completion: @escaping () -> Void) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if AXIsProcessTrusted() {
                completion()
            } else {
                self?.pollForAccessibility(attempts: attempts - 1, completion: completion)
            }
        }
    }

    private func showAlert(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: actionTitle)
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                action()
            }
        }
    }
}
