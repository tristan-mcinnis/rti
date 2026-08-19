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

@MainActor
final class OverlayWindowController {
    private let window: NSPanel
    private var frameSaveWorkItem: DispatchWorkItem?
    // Observer tokens are non-Sendable but only touched in init (set) and
    // deinit (read for removeObserver); marking nonisolated(unsafe) lets the
    // class stay @MainActor while keeping the cleanup path compileable.
    private nonisolated(unsafe) var didMoveObserver: NSObjectProtocol?
    private nonisolated(unsafe) var sizeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?

    init() {
        let initialSize = Self.configuredSize()
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = Self.keepsOverlayAboveOtherWindows
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = Self.keepsOverlayAboveOtherWindows ? .floating : .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // A window shadow separates the panel from the desktop — important in
        // light mode, where a pale panel otherwise blurs into a light background.
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView: OverlayPanelView())
        panel.appearance = Self.configuredAppearance()

        self.window = panel

        // queue: .main means these fire on the main thread; assumeIsolated
        // bridges the non-isolated callback into the class's MainActor.
        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveFrame()
            }
        }

        // Settings → "Overlay Appearance" sliders post this when width/height
        // change, so the live overlay resizes immediately.
        sizeObserver = NotificationCenter.default.addObserver(
            forName: .rtiOverlaySizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyConfiguredSize() }
        }

        // Settings → Appearance posts this so the panel re-themes live.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rtiOverlayAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window.appearance = Self.configuredAppearance()
                self?.applyConfiguredWindowLevel()
            }
        }

        if let saved = Self.loadSavedFrame() {
            window.setFrame(saved, display: false)
        } else {
            positionOnActiveScreen()
        }
    }

    deinit {
        if let o = didMoveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = sizeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appearanceObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// The NSAppearance the overlay should use, per the Settings theme mode.
    private static func configuredAppearance() -> NSAppearance? {
        switch OverlayAppearanceDefaults.effectiveAppearanceMode() {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    private static var keepsOverlayAboveOtherWindows: Bool {
        UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.alwaysOnTopKey) as? Bool
            ?? OverlayAppearanceDefaults.defaultAlwaysOnTop
    }

    private func applyConfiguredWindowLevel() {
        let keepAbove = Self.keepsOverlayAboveOtherWindows
        window.isFloatingPanel = keepAbove
        window.level = keepAbove ? .floating : .normal
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
        let margin: CGFloat = 16
        let configured = Self.configuredSize()
        let width: CGFloat = configured.width
        let height = min(configured.height, visible.height - margin * 2)
        let origin = NSPoint(
            x: visible.minX + margin,
            y: visible.maxY - margin - height
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

    func show(initialLaunch: Bool = false) {
        if initialLaunch {
            window.orderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        window.makeKey()
        if OverlayAppearanceDefaults.effectiveReduceMotion() {
            window.alphaValue = 1
        } else {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        }
    }

    func hide() {
        if OverlayAppearanceDefaults.effectiveReduceMotion() {
            window.orderOut(nil)
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            // runAnimationGroup's completion fires on the main thread, but
            // Swift's concurrency checker can't see that — assumeIsolated
            // bridges the non-isolated callback to MainActor explicitly.
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.alphaValue = 1
            }
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
            MainActor.assumeIsolated {
                guard let self, self.window.isVisible else { return }
                let frame = self.window.frame
                let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
                UserDefaults.standard.set(dict, forKey: savedFrameKey)
            }
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
