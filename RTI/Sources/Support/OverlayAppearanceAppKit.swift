import AppKit
import Foundation
import RTICore

extension OverlayAppearanceDefaults {
    /// The NSAppearance every RTI window (and `NSApp`) should carry, per the
    /// Settings theme. `nil` means "follow the system".
    static func nsAppearance() -> NSAppearance? {
        switch effectiveAppearanceMode() {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Apply the configured appearance app-wide. Called at launch and whenever
    /// the setting changes, so every window follows without per-window code.
    @MainActor
    static func applyAppAppearance() {
        NSApp.appearance = nsAppearance()
    }
}
