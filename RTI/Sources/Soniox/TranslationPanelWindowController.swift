import AppKit
import SwiftUI

private let translationSavedFrameKey = "rti.translationPanel.savedFrame"
let translationOpacityKey = "rti.translationPanel.opacity"
let translationDefaultOpacity: Double = 0.88
private let translationDefaultSize = NSSize(width: 460, height: 540)

private final class TranslationKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .rtiToggleTranslationPanel, object: nil)
    }
}

@MainActor
final class TranslationPanelWindowController: PanelWindowControlling {
    private let window: NSPanel
    private var frameSaveWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var didMoveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didResizeObserver: NSObjectProtocol?

    init() {
        let panel = TranslationKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: translationDefaultSize.width, height: translationDefaultSize.height),
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

        panel.contentView = NSHostingView(rootView: TranslationPanelView())

        self.window = panel

        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }

        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }

        if let saved = Self.loadSavedFrame() {
            window.setFrame(saved, display: false)
        } else {
            positionOnActiveScreen()
        }
    }

    deinit {
        if let o = didMoveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = didResizeObserver { NotificationCenter.default.removeObserver(o) }
    }

    var isVisible: Bool { window.isVisible }

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

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        let width = min(translationDefaultSize.width, visible.width - margin * 2)
        let height = min(translationDefaultSize.height, visible.height - margin * 2)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.maxY - height - margin - 60
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window.isVisible else { return }
            let frame = self.window.frame
            let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
            UserDefaults.standard.set(dict, forKey: translationSavedFrameKey)
        }
        frameSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: translationSavedFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
