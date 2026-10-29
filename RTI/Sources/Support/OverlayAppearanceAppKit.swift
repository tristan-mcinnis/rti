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

    static func effectiveReduceMotion() -> Bool {
        let raw = UserDefaults.standard.string(forKey: reduceMotionKey) ?? defaultReduceMotion
        let mode = RTIReduceMotionMode(rawValue: raw) ?? .system
        switch mode {
        case .system:
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .on:
            return true
        case .off:
            return false
        }
    }
}
