import AppKit
import SwiftUI

/// One floating NSPanel per spawned `UserPanel`. Picks the right view by
/// `panel.kind`. Frame is persisted per-panel so users see their layout
/// survive relaunches. Sharing type is set from the global invisibility
/// flag like the other RTI windows.
@MainActor
final class UserPanelWindowController: PanelWindowControlling {
    private let panelId: String
    private let window: NSPanel
    nonisolated(unsafe) private var didMoveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didResizeObserver: NSObjectProtocol?

    init(panel: UserPanel) {
        self.panelId = panel.id
        let size = Self.defaultSize(for: panel.kind)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true

        p.contentView = NSHostingView(rootView: AnyView(Self.rootView(for: panel)))
        self.window = p

        if let saved = Self.loadSavedFrame(panelId: panel.id) {
            window.setFrame(saved, display: false)
        } else {
            positionOnActiveScreen(size: size)
        }

        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.saveFrame() } }
        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.saveFrame() } }
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
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }

    /// Tear down so `WindowCoordinator` can drop its reference when the
    /// underlying panel is removed by the user.
    func close() {
        window.orderOut(nil)
        if let o = didMoveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = didResizeObserver { NotificationCenter.default.removeObserver(o) }
        didMoveObserver = nil
        didResizeObserver = nil
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private static func rootView(for panel: UserPanel) -> some View {
        switch panel.kind {
        case .counter:
            CounterPanelView(panel: panel)
        case .periodicCards:
            PeriodicCardsView(panel: panel)
        }
    }

    private static func defaultSize(for kind: PanelKind) -> NSSize {
        switch kind {
        case .counter:       return NSSize(width: 220, height: 150)
        case .periodicCards: return NSSize(width: 360, height: 420)
        }
    }

    private func positionOnActiveScreen(size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        // Stagger so spawned panels don't all pile on top of each other.
        let staggerSeed = abs(panelId.hashValue) % 6
        let origin = NSPoint(
            x: visible.maxX - size.width - margin - CGFloat(staggerSeed * 24),
            y: visible.maxY - size.height - margin - 120 - CGFloat(staggerSeed * 18)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func frameKey(panelId: String) -> String { "rti.userPanel.frame.\(panelId)" }

    private func saveFrame() {
        let frame = window.frame
        let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
        UserDefaults.standard.set(dict, forKey: Self.frameKey(panelId: panelId))
    }

    private static func loadSavedFrame(panelId: String) -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: frameKey(panelId: panelId)) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
