import AppKit

/// Every floating RTI panel window conforms to this. The four methods
/// (show, hide, toggle, setSharingInvisible) plus `isVisible` are the
/// complete surface `WindowCoordinator` needs to manage any panel, so
/// new panel types slot in without adding per-type methods on the
/// coordinator.
///
/// `FloatingPanelWindowController` adopts this today (the singleton-style
/// panels — Translation, configured via `FloatingPanelSpec`). Shortcuts
/// does not — it is a standard titled `NSWindow`.
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
