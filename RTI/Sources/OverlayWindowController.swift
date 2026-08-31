import AppKit
import SwiftUI

private let savedFrameKey = "rti.overlay.savedFrame"

/// The main RTI window. A standard titled window (close/minimize/zoom,
/// normal activation and key handling) — the earlier borderless
/// non-activating floating panel made basic window management (closing,
/// focusing) unpredictable.
private final class OverlayWindow: NSWindow {
    /// Called when the window transitions to key — used to auto-focus the input.
    /// Posting synchronously inside becomeKey re-enters layout because the
    /// SwiftUI focus change drives a layout pass while AppKit is still in one,
    /// which logs "_NSDetectedLayoutRecursion". Defer to the next runloop tick.
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        }
    }

    /// ESC dismisses the window — routes through the same toggle path as ⌘\
    /// so visibility state stays in one place.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .rtiToggleOverlay, object: nil)
    }
}

@MainActor
final class OverlayWindowController {
    private let window: NSWindow
    private var frameSaveWorkItem: DispatchWorkItem?
    // Observer tokens are non-Sendable but only touched in init (set) and
    // deinit (read for removeObserver); marking nonisolated(unsafe) lets the
    // class stay @MainActor while keeping the cleanup path compileable.
    private nonisolated(unsafe) var didMoveObserver: NSObjectProtocol?
    private nonisolated(unsafe) var didResizeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var sizeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?

    init(onOpenSettings: @Sendable @escaping () -> Void = {}) {
        let initialSize = Self.configuredSize()
        let win = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "RTI"
        // The controller owns the window for the app's lifetime; the close
        // button hides it (⌘\ or the menubar brings it back).
        win.isReleasedWhenClosed = false
        win.sharingType = .none
        win.isMovableByWindowBackground = true

        win.contentView = NSHostingView(rootView: OverlayPanelView(onOpenSettings: onOpenSettings))
        win.appearance = Self.configuredAppearance()

        self.window = win
        applyConfiguredWindowLevel()

        // queue: .main means these fire on the main thread; assumeIsolated
        // bridges the non-isolated callback into the class's MainActor.
        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveFrame()
            }
        }

        // The window is user-resizable now — persist size changes the same
        // way as moves.
        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveFrame()
            }
        }

        // Settings → "Overlay Appearance" sliders post this when width/height
        // change, so the live window resizes immediately.
        sizeObserver = NotificationCenter.default.addObserver(
            forName: .rtiOverlaySizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyConfiguredSize() }
        }

        // Settings → Appearance posts this so the window re-themes live.
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
        if let o = didResizeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = sizeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appearanceObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// The NSAppearance the window should use, per the Settings theme mode.
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

    /// "Always on top" keeps the meeting workflow working: the window floats
    /// over the call app and follows into full-screen spaces. Off = a fully
    /// normal window.
    private func applyConfiguredWindowLevel() {
        let keepAbove = Self.keepsOverlayAboveOtherWindows
        window.level = keepAbove ? .floating : .normal
        window.collectionBehavior = keepAbove
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .participatesInCycle]
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

    /// Resize the window in place when the user drags a Settings slider.
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        }
    }

    func hide() {
        window.orderOut(nil)
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
        // Debounce: didMove/didResize fire per pixel of drag. Without this
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
