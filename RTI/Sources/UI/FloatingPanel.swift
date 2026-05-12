import AppKit
import SwiftUI

/// Identifier for each singleton floating panel. Drives the `spec`
/// lookup and lets `WindowCoordinator` iterate panels generically
/// (e.g. "hide every panel on `rtiHideAuxiliaryPanels`") without
/// hand-rolling the same 5 lines for each kind.
enum FloatingPanelID: CaseIterable {
    case notes
    case dossiers
    case themes
    case discussionGuide
    case translation

    @MainActor
    var spec: FloatingPanelSpec {
        switch self {
        case .notes:           return .notes
        case .dossiers:        return .dossiers
        case .themes:          return .themes
        case .discussionGuide: return .discussionGuide
        case .translation:     return .translation
        }
    }
}

/// Configuration for a singleton floating panel: a borderless `NSPanel`
/// that floats above all other windows, fades in/out, persists its frame
/// across launches, and toggles `sharingType` with the rest of the app's
/// invisible-to-screen-capture mode.
///
/// Five panels are built this way (Notes, Dossiers, Themes, DiscussionGuide,
/// Translation). `UserPanelWindowController` is intentionally not folded in
/// because user panels have per-instance lifecycle (spawn, teardown,
/// per-id frame keys); collapsing it here would re-introduce more
/// complexity than it removes.
struct FloatingPanelSpec {
    let savedFrameKey: String
    let opacityKey: String
    let opacityDefault: Double
    let defaultSize: NSSize
    /// Posted when the user hits Escape while the panel is key. The
    /// app-level handler decides whether to toggle the panel or do
    /// something else. `nil` falls back to NSPanel's default behavior.
    let escapeNotification: Notification.Name?
    /// Computes the origin used when no saved frame exists. Receives the
    /// active screen's `visibleFrame` and the clamped panel size.
    let initialOrigin: (_ visibleFrame: NSRect, _ size: NSSize) -> NSPoint
    /// The SwiftUI root view embedded in the panel.
    let makeRootView: @MainActor () -> AnyView
}

@MainActor
extension FloatingPanelSpec {
    static let notes = FloatingPanelSpec(
        savedFrameKey: "rti.notesPanel.savedFrame",
        opacityKey: notesOpacityKey,
        opacityDefault: notesDefaultOpacity,
        defaultSize: NSSize(width: 380, height: 500),
        escapeNotification: .rtiToggleNotesPanel,
        initialOrigin: { visible, size in
            NSPoint(x: visible.minX + 16, y: visible.maxY - size.height - 16 - 80)
        },
        makeRootView: { AnyView(NotesPanelView()) }
    )

    static let dossiers = FloatingPanelSpec(
        savedFrameKey: "rti.dossiersPanel.savedFrame",
        opacityKey: dossiersOpacityKey,
        opacityDefault: dossiersDefaultOpacity,
        defaultSize: NSSize(width: 420, height: 500),
        escapeNotification: .rtiToggleDossiersPanel,
        initialOrigin: { visible, size in
            NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16 - 80)
        },
        makeRootView: { AnyView(DossiersPanelView()) }
    )

    static let themes = FloatingPanelSpec(
        savedFrameKey: "rti.themesPanel.savedFrame",
        opacityKey: themesOpacityKey,
        opacityDefault: themesDefaultOpacity,
        defaultSize: NSSize(width: 420, height: 560),
        escapeNotification: .rtiToggleThemesPanel,
        initialOrigin: { visible, size in
            NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16 - 80)
        },
        makeRootView: { AnyView(ThemesPanelView()) }
    )

    static let discussionGuide = FloatingPanelSpec(
        savedFrameKey: "rti.guidePanel.savedFrame",
        opacityKey: guideOpacityKey,
        opacityDefault: guideDefaultOpacity,
        defaultSize: NSSize(width: 440, height: 580),
        escapeNotification: .rtiToggleGuidePanel,
        initialOrigin: { visible, size in
            NSPoint(x: visible.minX + 16, y: visible.maxY - size.height - 16 - 220)
        },
        makeRootView: { AnyView(DiscussionGuidePanelView()) }
    )

    static let translation = FloatingPanelSpec(
        savedFrameKey: "rti.translationPanel.savedFrame",
        opacityKey: translationOpacityKey,
        opacityDefault: translationDefaultOpacity,
        defaultSize: NSSize(width: 460, height: 540),
        escapeNotification: .rtiToggleTranslationPanel,
        initialOrigin: { visible, size in
            NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16 - 60)
        },
        makeRootView: { AnyView(TranslationPanelView()) }
    )
}

// MARK: - Opacity defaults

// Top-level so the existing `@AppStorage(notesOpacityKey)` etc. call sites
// in panel views keep compiling unchanged.

let notesOpacityKey = "rti.notesPanel.opacity"
let notesDefaultOpacity: Double = 0.88

let dossiersOpacityKey = "rti.dossiersPanel.opacity"
let dossiersDefaultOpacity: Double = 0.88

let themesOpacityKey = "rti.themesPanel.opacity"
let themesDefaultOpacity: Double = 0.88

let guideOpacityKey = "rti.guidePanel.opacity"
let guideDefaultOpacity: Double = 0.88

let translationOpacityKey = "rti.translationPanel.opacity"
let translationDefaultOpacity: Double = 0.88

// MARK: - Controller

private final class EscapeAwareNSPanel: NSPanel {
    var escapeNotification: Notification.Name?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let name = escapeNotification {
            NotificationCenter.default.post(name: name, object: nil)
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
        panel.escapeNotification = spec.escapeNotification
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: spec.makeRootView())

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
            let frame = self.window.frame
            let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
            UserDefaults.standard.set(dict, forKey: key)
        }
        frameSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func loadSavedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: spec.savedFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
