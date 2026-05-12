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
        RTIPanelDefaults.apply(to: p, rootView: AnyView(Self.rootView(for: panel)))
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

    func show() { RTIPanelDefaults.fadeIn(window) }

    func hide() { RTIPanelDefaults.fadeOut(window, duration: 0.12) }

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
        RTIPanelDefaults.saveFrame(window.frame, key: Self.frameKey(panelId: panelId))
    }

    private static func loadSavedFrame(panelId: String) -> NSRect? {
        RTIPanelDefaults.loadFrame(key: frameKey(panelId: panelId))
    }
}
