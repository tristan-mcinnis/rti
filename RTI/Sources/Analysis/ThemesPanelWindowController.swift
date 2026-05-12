import AppKit
import SwiftUI

private let themesSavedFrameKey = "rti.themesPanel.savedFrame"
let themesOpacityKey = "rti.themesPanel.opacity"
let themesDefaultOpacity: Double = 0.88
private let themesDefaultSize = NSSize(width: 420, height: 560)

private final class ThemesKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .rtiToggleThemesPanel, object: nil)
    }
}

@MainActor
final class ThemesPanelWindowController {
    private let window: NSPanel
    private var frameSaveWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var didMoveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didResizeObserver: NSObjectProtocol?

    init() {
        let panel = ThemesKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: themesDefaultSize.width, height: themesDefaultSize.height),
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

        panel.contentView = NSHostingView(rootView: ThemesPanelView())

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

    func toggle() {
        if window.isVisible { hide() } else { show() }
    }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        let width = min(themesDefaultSize.width, visible.width - margin * 2)
        let height = min(themesDefaultSize.height, visible.height - margin * 2)
        let origin = NSPoint(
            x: visible.maxX - width - margin,
            y: visible.maxY - height - margin - 80
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window.isVisible else { return }
            let frame = self.window.frame
            let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
            UserDefaults.standard.set(dict, forKey: themesSavedFrameKey)
        }
        frameSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: themesSavedFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
