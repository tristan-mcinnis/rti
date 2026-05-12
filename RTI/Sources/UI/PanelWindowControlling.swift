import AppKit

/// Every floating RTI panel window conforms to this. The four methods
/// (show, hide, toggle, setSharingInvisible) plus `isVisible` are the
/// complete surface `WindowCoordinator` needs to manage any panel, so
/// new panel types slot in without adding per-type methods on the
/// coordinator.
///
/// Six controllers adopt this today: Notes, Dossiers, Themes,
/// DiscussionGuide, Translation, and UserPanel. CommandPalette and
/// Shortcuts do not — CommandPalette has a different anchoring model
/// (child-window of Sessions Control), and Shortcuts is a standard
/// titled `NSWindow`.
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
