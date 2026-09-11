import AppKit
import Carbon.HIToolbox
import Observation
import RTICore
import SwiftUI

/// The legacy frame key from before the frame was autosaved by name. Read
/// once, so an existing window keeps its place; never written again.
private let legacySavedFrameKey = "rti.overlay.savedFrame"

// MARK: - Window chrome state

/// What the overlay's views read about the window itself
/// (chat-surfaces.md section 7).
@Observable @MainActor
final class OverlayWindowChrome {
    static let shared = OverlayWindowChrome()

    /// In full screen the traffic lights are hidden, so the header drops the
    /// room it keeps for them.
    var isFullScreen = false

    /// Window › Keep on Top. In memory only and off at every launch: RTI
    /// dropped the always-on-top float as its default on 1 Sep, so floating
    /// over a call is a deliberate, per-launch choice.
    var isKeptOnTop = false {
        didSet {
            guard isKeptOnTop != oldValue else { return }
            onKeepOnTopChange?(isKeptOnTop)
        }
    }

    @ObservationIgnored var onKeepOnTopChange: ((Bool) -> Void)?

    private init() {}
}

// MARK: - esc

/// Routes `esc` in the overlay through the house order
/// (`OverlayEscapeOrder`): a layer, then the find bar, then the stream, then
/// typed text, then nothing. It never hides the window.
///
/// The surfaces that own a layer, the find bar, or the draft register here;
/// the stream is `LLMController`'s. Registrations are closures so this file
/// needs no knowledge of the views that own the state.
@MainActor
final class OverlayEscapeRouter {
    static let shared = OverlayEscapeRouter()

    /// Something that can be open over the thread or composer.
    struct Closable {
        let isOpen: () -> Bool
        let close: () -> Void
    }

    /// Floating layers by owner ("header.chooser", "composer.chooser",
    /// "composer.palette"). Any open one is closed first.
    private var layers: [String: Closable] = [:]
    /// The find bar (Assist thread).
    var findBar: Closable?
    /// The composer's draft. `isOpen` means "the composer has focus and holds
    /// text"; `close` clears it.
    var draft: Closable?
    /// The streaming answer. Defaults to `LLMController`.
    var stream = Closable(
        isOpen: { LLMController.shared.streaming },
        close: { LLMController.shared.cancel() }
    )

    private init() {}

    func registerLayer(_ id: String, isOpen: @escaping () -> Bool, close: @escaping () -> Void) {
        layers[id] = Closable(isOpen: isOpen, close: close)
    }

    func unregisterLayer(_ id: String) {
        layers[id] = nil
    }

    func state(hasMarkedText: Bool) -> OverlayEscapeState {
        OverlayEscapeState(
            hasMarkedText: hasMarkedText,
            isLayerOpen: layers.values.contains { $0.isOpen() },
            isFindOpen: findBar?.isOpen() ?? false,
            isStreaming: stream.isOpen(),
            hasTypedText: draft?.isOpen() ?? false
        )
    }

    /// Decide and act. Returns what was done.
    @discardableResult
    func handleEscape(hasMarkedText: Bool = false) -> OverlayEscapeAction {
        let action = OverlayEscapeOrder.action(for: state(hasMarkedText: hasMarkedText))
        switch action {
        case .closeLayer:
            layers.values.first { $0.isOpen() }?.close()
        case .closeFind:
            findBar?.close()
        case .stopStream:
            stream.close()
        case .clearText:
            draft?.close()
        case .passToInputMethod, .nothing:
            break
        }
        return action
    }
}

// MARK: - Window

/// The overlay's NSWindow. `esc` is taken in `sendEvent`, before a text view
/// can turn it into completion, and goes through `OverlayEscapeRouter`. An
/// input method's composition keeps `esc`, and a single-line field (a
/// speaker rename, a search field) handles its own first.
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, Self.isPlainEscape(event) {
            let textView = firstResponder as? NSTextView
            if textView?.hasMarkedText() == true {
                super.sendEvent(event)
                return
            }
            if textView?.isFieldEditor != true, OverlayEscapeRouter.shared.handleEscape().handlesKey {
                return
            }
        }
        super.sendEvent(event)
    }

    /// `esc` that no control took. It used to hide the window; now it pops a
    /// layer or does nothing, so a stray press never hides the cockpit.
    override func cancelOperation(_ sender: Any?) {
        OverlayEscapeRouter.shared.handleEscape()
    }

    /// ⌘W hides the window (the close button's path) even when no menu item
    /// carries the key. Recording and streaming go on.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Escape)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

/// Owns the overlay window: a normal titled window in the house window chrome
/// (chat-surfaces.md section 7), adapted for RTI. RTI is always a regular
/// Dock app, so there is no activation-policy switching; the window hides on
/// close and is never released; it is always `sharingType = .none`.
@MainActor
final class OverlayWindowController {
    static let frameAutosaveName = "RTI.OverlayWindow"

    private let window: NSWindow
    // Observer tokens are non-Sendable but only touched in init (set) and
    // deinit (read for removeObserver); marking nonisolated(unsafe) lets the
    // class stay @MainActor while keeping the cleanup path compileable.
    private nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?
    private nonisolated(unsafe) var enterFullScreenObserver: NSObjectProtocol?
    private nonisolated(unsafe) var exitFullScreenObserver: NSObjectProtocol?

    init(onOpenSettings: @Sendable @escaping () -> Void = {}) {
        let initialSize = Self.configuredSize()
        let win = OverlayWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The title names the window to VoiceOver and Mission Control; it is
        // not drawn (the header carries the title).
        win.title = "RTI"
        win.identifier = NSUserInterfaceItemIdentifier(RTIWindowKind.overlay.windowIdentifier)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title-bar row as tall as the 52
        // header, so the traffic lights centre on the header's row; the
        // content runs up under it (`ignoresSafeArea` in the view).
        let toolbar = NSToolbar(identifier: "RTIOverlayWindow")
        win.toolbar = toolbar
        win.toolbarStyle = .unified
        // Selecting transcript or answer text must not drag the window; the
        // header carries the drag (`WindowDragArea`).
        win.isMovableByWindowBackground = false
        // The controller owns the window for the app's lifetime; the close
        // button and ⌘W hide it (⌘\ or the menu bar brings it back).
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        // Window › RTI opens it even while hidden; the automatic window
        // list would only add a second "RTI" entry.
        win.isExcludedFromWindowsMenu = true
        win.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        win.sharingType = .none
        // Opaque `surface` ground, not glass: cheaper to composite during a
        // call, and the same ground as every house chat window.
        win.isOpaque = true
        win.backgroundColor = House.NSColorToken.surface
        win.contentMinSize = NSSize(
            width: OverlayAppearanceDefaults.widthRange.lowerBound,
            height: OverlayAppearanceDefaults.heightRange.lowerBound
        )

        let hosting = NSHostingView(rootView: OverlayPanelView(onOpenSettings: onOpenSettings))
        // The window sizes the view, not the other way round: the frame is
        // the user's (autosaved), from the minimum up.
        hosting.sizingOptions = []
        win.contentView = hosting
        win.appearance = Self.configuredAppearance()

        self.window = win

        // Settings → Appearance posts this so the window re-themes live.
        // queue: .main means it fires on the main thread; assumeIsolated
        // bridges the non-isolated callback into the class's MainActor.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rtiOverlayAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                OverlayAppearanceDefaults.applyAppAppearance()
                self?.window.appearance = Self.configuredAppearance()
            }
        }
        enterFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: win,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { OverlayWindowChrome.shared.isFullScreen = true }
        }
        exitFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: win,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { OverlayWindowChrome.shared.isFullScreen = false }
        }
        OverlayWindowChrome.shared.onKeepOnTopChange = { [weak win] onTop in
            win?.level = onTop ? .floating : .normal
        }

        restoreFrame()
    }

    deinit {
        if let o = appearanceObserver { NotificationCenter.default.removeObserver(o) }
        if let o = enterFullScreenObserver { NotificationCenter.default.removeObserver(o) }
        if let o = exitFullScreenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// The NSAppearance the window should use, per the Settings theme mode.
    /// One resolver for every RTI window (`OverlayAppearanceDefaults`).
    private static func configuredAppearance() -> NSAppearance? {
        OverlayAppearanceDefaults.nsAppearance()
    }

    /// The first-launch size: the size a user last set with the retired
    /// width and height sliders, else 700 × 440. The keys are only read now;
    /// the autosaved frame is the size from here on.
    private static func configuredSize() -> NSSize {
        let d = UserDefaults.standard
        let storedWidth = d.double(forKey: OverlayAppearanceDefaults.widthKey)
        let storedHeight = d.double(forKey: OverlayAppearanceDefaults.heightKey)
        let width = storedWidth > 0 ? storedWidth : OverlayAppearanceDefaults.defaultWidth
        let height = storedHeight > 0 ? storedHeight : OverlayAppearanceDefaults.defaultHeight
        return NSSize(
            width: min(max(width, OverlayAppearanceDefaults.widthRange.lowerBound), OverlayAppearanceDefaults.widthRange.upperBound),
            height: min(max(height, OverlayAppearanceDefaults.heightRange.lowerBound), OverlayAppearanceDefaults.heightRange.upperBound)
        )
    }

    // MARK: - Frame

    /// The autosaved frame, else the pre-autosave frame, else top-left of the
    /// screen under the pointer. A frame under the minimum comes back at the
    /// standard size.
    private func restoreFrame() {
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            if let legacy = Self.loadLegacySavedFrame() {
                window.setFrame(legacy, display: false)
            } else {
                positionOnActiveScreen()
            }
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        let content = window.contentRect(forFrameRect: window.frame).size
        if content.width < window.contentMinSize.width || content.height < window.contentMinSize.height {
            window.setContentSize(Self.configuredSize())
            positionOnActiveScreen()
        }
    }

    func positionOnActiveScreen() {
        let screen = screenUnderMouse() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin = House.Spacing.md
        let content = Self.configuredSize()
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        let height = min(frameSize.height, visible.height - margin * 2)
        let origin = NSPoint(
            x: visible.minX + margin,
            y: visible.maxY - margin - height
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: frameSize.width, height: height)), display: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private static func loadLegacySavedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: legacySavedFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        // Only when it is still on some screen.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    // MARK: - Showing

    var isVisible: Bool { window.isVisible }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }

    func show(initialLaunch: Bool = false) {
        // Bring RTI forward with the keyboard, even from another app (the
        // global ⌘\ key), so typing lands in the composer, not behind it.
        RTIActivation.bringToFront(window)
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
}
