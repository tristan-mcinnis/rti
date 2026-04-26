import AppKit
import SwiftUI

private let savedFrameKey = "rti.overlay.savedFrame"

/// Non-activating panel that still accepts keyboard input when clicked,
/// so the text field works without activating RTI over the meeting app.
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when the panel transitions to key — used to auto-focus the input.
    override func becomeKey() {
        super.becomeKey()
        NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
    }

    /// ESC dismisses the overlay — universal expectation for transient surfaces.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

final class OverlayWindowController {
    private let window: NSPanel
    private var frameSaveWorkItem: DispatchWorkItem?

    init(onOpenSettings: @escaping () -> Void = {}) {
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView: OverlayPanelView(onOpenSettings: onOpenSettings))

        self.window = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.saveFrame() }

        if let saved = Self.loadSavedFrame() {
            window.setFrame(saved, display: false)
        } else {
            positionOnActiveScreen()
        }
    }

    func positionOnActiveScreen() {
        let screen = screenUnderMouse() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let widgetReserve: CGFloat = 72
        let margin: CGFloat = 16
        let width: CGFloat = 480
        let height = min(600, visible.height - widgetReserve - margin)
        let origin = NSPoint(
            x: visible.minX + margin,
            y: visible.maxY - widgetReserve - height
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    func show() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    func toggle() {
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Frame persistence

    private func saveFrame() {
        // Debounce: didMoveNotification fires per pixel of drag. Without this
        // we'd hit UserDefaults dozens of times per second during a drag.
        frameSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window.isVisible else { return }
            let frame = self.window.frame
            let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
            UserDefaults.standard.set(dict, forKey: savedFrameKey)
        }
        frameSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: savedFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        // Validate the frame is still on some screen
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
