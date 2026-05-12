import AppKit

/// Every floating RTI panel window conforms to this. The four methods
/// (show, hide, toggle, setSharingInvisible) plus `isVisible` are the
/// complete surface `WindowCoordinator` needs to manage any panel, so
/// new panel types slot in without adding per-type methods on the
/// coordinator.
///
/// Two controllers adopt this today: `FloatingPanelWindowController`
/// (the singleton-style panels — Notes, Dossiers, Themes,
/// DiscussionGuide, Translation, all configured via `FloatingPanelSpec`)
/// and `UserPanelWindowController` (the dynamically-spawned user panels).
/// CommandPalette and Shortcuts do not — CommandPalette has a different
/// anchoring model (child-window of Sessions Control), and Shortcuts is a
/// standard titled `NSWindow`.
///
/// Main-actor isolated because every conformer manipulates AppKit windows.
@MainActor
protocol PanelWindowControlling: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func toggle()
    func setSharingInvisible(_ invisible: Bool)
}

extension PanelWindowControlling {
    func toggle() {
        if isVisible { hide() } else { show() }
    }
}
