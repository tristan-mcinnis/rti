import AppKit
import SwiftUI

private let savedFrameKey = "rti.overlay.savedFrame"

/// Non-activating panel that still accepts keyboard input when clicked,
/// so the text field works without activating RTI over the meeting app.
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when the panel transitions to key — used to auto-focus the input.
    /// Posting synchronously inside becomeKey re-enters layout because the
    /// SwiftUI focus change drives a layout pass while AppKit is still in one,
    /// which logs "_NSDetectedLayoutRecursion". Defer to the next runloop tick.
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        }
    }

    /// ESC dismisses the overlay — universal expectation for transient surfaces.
    /// Posts a notification so the controller can route through hide() and keep
    /// alphaValue / isVisible in sync, instead of calling orderOut directly.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .rtiToggleOverlay, object: nil)
    }
}

final class OverlayWindowController {
    private let window: NSPanel
    private var frameSaveWorkItem: DispatchWorkItem?
    private var didMoveObserver: NSObjectProtocol?
    private var didResizeObserver: NSObjectProtocol?
    private var sizeObserver: NSObjectProtocol?
    /// The top-widget pill, attached as a child window so it tracks the
    /// overlay's position and visibility. Repositioned on every move/resize
    /// so it stays glued to the top-right corner.
    private weak var attachedPill: NSWindow?

    init(onOpenSettings: @escaping () -> Void = {}) {
        let initialSize = Self.configuredSize()
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
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

        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.saveFrame()
            self?.repositionPill()
        }

        // Reanchor the pill on resize. addChildWindow keeps the child at a
        // fixed offset from the parent's origin, but we want it pinned to the
        // top-right — so we recompute every resize tick.
        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.repositionPill() }

        // Settings → "Overlay Appearance" sliders post this when width/height
        // change, so the live overlay resizes immediately.
        sizeObserver = NotificationCenter.default.addObserver(
            forName: .rtiOverlaySizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.applyConfiguredSize() }

        if let saved = Self.loadSavedFrame() {
            window.setFrame(saved, display: false)
        } else {
            positionOnActiveScreen()
        }
    }

    deinit {
        if let o = didMoveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = didResizeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = sizeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Attached pill (top-widget)

    /// Wire the top-widget pill as a child window so it (a) tracks the
    /// overlay's position automatically, (b) inherits visibility — when the
    /// overlay is ordered out, the pill is too. Repositioning is still
    /// manual on resize since AppKit only auto-tracks moves.
    func attachPill(_ pill: NSWindow) {
        if let existing = pill.parent {
            existing.removeChildWindow(pill)
        }
        window.addChildWindow(pill, ordered: .above)
        attachedPill = pill
        repositionPill()
    }

    /// Pin the pill to the overlay's top-right, sticking up just above the
    /// panel like a tab handle. Right edges align so the pill never crosses
    /// the panel's right border, and it never overlaps the response area.
    private func repositionPill() {
        guard let pill = attachedPill else { return }
        let frame = window.frame
        let pw = pill.frame.width
        let gap: CGFloat = 4
        let x = frame.maxX - pw
        let y = frame.maxY + gap
        pill.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func configuredSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: OverlayAppearanceDefaults.widthKey)
        let h = d.double(forKey: OverlayAppearanceDefaults.heightKey)
        return NSSize(
            width: w > 0 ? w : OverlayAppearanceDefaults.defaultWidth,
            height: h > 0 ? h : OverlayAppearanceDefaults.defaultHeight
        )
    }

    /// Resize the overlay in place when the user drags a Settings slider.
    /// Keeps the current top-left origin so the window doesn't jump.
    private func applyConfiguredSize() {
        let newSize = Self.configuredSize()
        let currentFrame = window.frame
        // NSWindow origin is bottom-left; preserve top-left by adjusting y.
        let newOriginY = currentFrame.maxY - newSize.height
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: newSize.width,
            height: newSize.height
        )
        window.setFrame(newFrame, display: true, animate: false)
        saveFrame()
    }

    func positionOnActiveScreen() {
        let screen = screenUnderMouse() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let widgetReserve: CGFloat = 72
        let margin: CGFloat = 16
        let configured = Self.configuredSize()
        let width: CGFloat = configured.width
        let height = min(configured.height, visible.height - widgetReserve - margin)
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

    var isVisible: Bool { window.isVisible }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
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
