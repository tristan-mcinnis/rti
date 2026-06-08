import AppKit
import SwiftUI

/// Overlay theme colors that resolve against the panel's effective NSAppearance,
/// so the whole surface flips with the Settings → "Light mode" toggle (which
/// drives `preferredColorScheme` + the panel's `NSAppearance`).
///
/// The trick: keep one "ink" color (white in dark, black in light). Because the
/// codebase expresses hierarchy as `ink.opacity(x)`, every existing opacity
/// value keeps reading correctly on either background — no per-call remapping.
extension Color {
    /// Primary text/control color — white in dark mode, black in light mode.
    static let overlayInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })

    /// The overlay panel fill — near-black in dark mode, near-white in light.
    static let overlayPanel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    })

    /// The panel's outer border. Stronger in light mode — a faint white edge
    /// reads fine on a dark background, but a faint black edge blurs into a light
    /// one, so light mode needs more contrast to define the window.
    static let overlayBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.28)
    })
}
