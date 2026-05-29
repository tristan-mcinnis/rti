import AppKit
import SwiftUI

/// Identifier for each singleton floating panel. Drives the `spec`
/// lookup and lets `WindowCoordinator` iterate panels generically
/// (e.g. "hide every panel on `rtiHideAuxiliaryPanels`") without
/// hand-rolling the same 5 lines for each kind.
enum FloatingPanelID: CaseIterable {
    case notes
    case dossiers
    case discussionGuide
    case translation

    @MainActor
    var spec: FloatingPanelSpec {
        switch self {
        case .notes: return .notes
        case .dossiers: return .dossiers
        case .discussionGuide: return .discussionGuide
        case .translation: return .translation
        }
    }
}

/// Configuration for a singleton floating panel: a borderless `NSPanel`
/// that floats above all other windows, fades in/out, persists its frame
/// across launches, and toggles `sharingType` with the rest of the app's
/// invisible-to-screen-capture mode.
///
/// The Translation panel is built this way.
struct FloatingPanelSpec {
    let savedFrameKey: String
    let opacityKey: String
    let opacityDefault: Double
    let defaultSize: NSSize
    /// Panel identity — used by the Esc handler to ask the
    /// `WindowCoordinator` to toggle this panel. `nil` falls back to
    /// NSPanel's default cancel behavior.
    let panelID: FloatingPanelID?
    /// Computes the origin used when no saved frame exists. Receives the
    /// active screen's `visibleFrame` and the clamped panel size.
    let initialOrigin: (_ visibleFrame: NSRect, _ size: NSSize) -> NSPoint
    /// The SwiftUI root view embedded in the panel.
    let makeRootView: @MainActor () -> AnyView
}

@MainActor
extension FloatingPanelSpec {
    static let notes = FloatingPanelSpec(
        savedFrameKey: "rti.notesPanel.savedFrame.v2",
        opacityKey: notesOpacityKey,
        opacityDefault: floatingPanelDefaultOpacity,
        defaultSize: floatingPanelDefaultSize,
        panelID: .notes,
        initialOrigin: { visible, size in
            NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        },
        makeRootView: { AnyView(NotesPanelView()) }
    )

    static let dossiers = FloatingPanelSpec(
        savedFrameKey: "rti.dossiersPanel.savedFrame.v2",
        opacityKey: dossiersOpacityKey,
        opacityDefault: floatingPanelDefaultOpacity,
        defaultSize: floatingPanelDefaultSize,
        panelID: .dossiers,
        initialOrigin: { visible, size in
            NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        },
        makeRootView: { AnyView(DossiersPanelView()) }
    )

    static let discussionGuide = FloatingPanelSpec(
        savedFrameKey: "rti.guidePanel.savedFrame.v2",
        opacityKey: guideOpacityKey,
        opacityDefault: floatingPanelDefaultOpacity,
        defaultSize: floatingPanelDefaultSize,
        panelID: .discussionGuide,
        initialOrigin: { visible, size in
            NSPoint(x: visible.minX + 16, y: visible.maxY - size.height - 16)
        },
        makeRootView: { AnyView(DiscussionGuidePanelView()) }
    )

    static let translation = FloatingPanelSpec(
        savedFrameKey: "rti.translationPanel.savedFrame.v2",
        opacityKey: translationOpacityKey,
        opacityDefault: floatingPanelDefaultOpacity,
        defaultSize: floatingPanelDefaultSize,
        panelID: .translation,
        initialOrigin: { visible, size in
            NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16 - 60)
        },
        makeRootView: { AnyView(TranslationPanelView()) }
    )
}

// MARK: - Shared defaults

/// Single source of truth — every floating panel starts at the same size
/// and opacity. Per-panel keys still exist so a user can drift one panel
/// individually via the ⋯ menu without resetting the rest. The
/// `.v2` suffix on `savedFrameKey` above invalidates any pre-unification
/// stored frames so the new defaults actually take effect on first open.
let floatingPanelDefaultSize = NSSize(width: 420, height: 540)
let floatingPanelDefaultOpacity: Double = 0.88

let notesOpacityKey = "rti.notesPanel.opacity"
let notesDefaultOpacity: Double = floatingPanelDefaultOpacity

let dossiersOpacityKey = "rti.dossiersPanel.opacity"
let dossiersDefaultOpacity: Double = floatingPanelDefaultOpacity

let guideOpacityKey = "rti.guidePanel.opacity"
let guideDefaultOpacity: Double = floatingPanelDefaultOpacity

let translationOpacityKey = "rti.translationPanel.opacity"
let translationDefaultOpacity: Double = floatingPanelDefaultOpacity

// MARK: - Controller

private final class EscapeAwareNSPanel: NSPanel {
    var panelID: FloatingPanelID?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let id = panelID {
            MainActor.assumeIsolated { WindowCoordinator.shared.toggle(id) }
        } else {
            super.cancelOperation(sender)
        }
    }
}

@MainActor
final class FloatingPanelWindowController: PanelWindowControlling {
    private let spec: FloatingPanelSpec
    private let window: EscapeAwareNSPanel
    private var frameSaveWorkItem: DispatchWorkItem?
    // Held without Sendable annotations so the nonisolated deinit can read
    // them. They're set during init (main-actor) and only read again there.
    nonisolated(unsafe) private var didMoveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didResizeObserver: NSObjectProtocol?

    init(spec: FloatingPanelSpec) {
        self.spec = spec

        let panel = EscapeAwareNSPanel(
            contentRect: NSRect(origin: .zero, size: spec.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.panelID = spec.panelID
        RTIPanelDefaults.apply(to: panel, rootView: spec.makeRootView())

        self.window = panel

        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }

        if let saved = loadSavedFrame() {
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

    func show() { RTIPanelDefaults.fadeIn(window) }

    func hide() { RTIPanelDefaults.fadeOut(window) }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16
        let width = min(spec.defaultSize.width, visible.width - margin * 2)
        let height = min(spec.defaultSize.height, visible.height - margin * 2)
        let size = NSSize(width: width, height: height)
        let origin = spec.initialOrigin(visible, size)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        let key = spec.savedFrameKey
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window.isVisible else { return }
            RTIPanelDefaults.saveFrame(self.window.frame, key: key)
        }
        frameSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func loadSavedFrame() -> NSRect? {
        RTIPanelDefaults.loadFrame(key: spec.savedFrameKey)
    }
}
