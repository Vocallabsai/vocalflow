import AppKit
import SwiftUI

class RecordingOverlayController {
    private var panel: NSPanel?

    init() {
        buildPanel()
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        panel.contentView = NSHostingView(rootView: WaveformOverlayView())
        panel.contentView?.wantsLayer = true

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel = panel,
              let screenFrame = NSScreen.main?.visibleFrame else { return }

        let size = panel.contentView?.fittingSize ?? CGSize(width: 120, height: 52)
        panel.setContentSize(size)

        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        guard let panel = panel else { return }
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }
}
