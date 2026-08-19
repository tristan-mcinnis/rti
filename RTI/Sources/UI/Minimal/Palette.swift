import AppKit
import SwiftUI

/// Semantic color tokens for the minimal UI. One place, no primitives
/// elsewhere. Dynamic NSColor-backed so appearance changes at runtime
/// (same pattern as OverlayTheme.swift). Dark values are authored
/// separately, not mirrored from light, so contrast is tuned per mode.
enum Palette {
    // MARK: - Surfaces

    static let surfacePanel = dynamic(
        light: NSColor(white: 1.0, alpha: 1),
        dark: NSColor(white: 0.095, alpha: 1)
    )

    static let surfaceRaised = dynamic(
        light: NSColor(white: 0.98, alpha: 1),
        dark: NSColor(white: 0.145, alpha: 1)
    )

    static let surfaceInput = dynamic(
        light: NSColor(white: 0.965, alpha: 1),
        dark: NSColor(white: 0.16, alpha: 1)
    )

    // MARK: - Borders

    static let borderHairline = dynamic(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.12)
    )

    static let borderFocus = dynamic(
        light: NSColor.systemBlue.withAlphaComponent(0.65),
        dark: NSColor.systemBlue.withAlphaComponent(0.75)
    )

    // MARK: - Ink

    static let inkPrimary = dynamic(
        light: NSColor(white: 0.12, alpha: 1),
        dark: NSColor(white: 0.94, alpha: 1)
    )

    static let inkSecondary = dynamic(
        light: NSColor(white: 0.35, alpha: 1),
        dark: NSColor(white: 0.72, alpha: 1)
    )

    static let inkFaint = dynamic(
        light: NSColor(white: 0.55, alpha: 1),
        dark: NSColor(white: 0.5, alpha: 1)
    )

    // MARK: - Accent

    static let accentSolid = dynamic(
        light: NSColor.systemBlue,
        dark: NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
    )

    static let accentWash = dynamic(
        light: NSColor.systemBlue.withAlphaComponent(0.10),
        dark: NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 0.16)
    )

    // MARK: - State

    static let stateIdle = dynamic(
        light: NSColor(white: 0.6, alpha: 1),
        dark: NSColor(white: 0.55, alpha: 1)
    )

    static let stateLive = dynamic(
        light: NSColor.systemGreen,
        dark: NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
    )

    static let stateWarn = dynamic(
        light: NSColor.systemOrange,
        dark: NSColor(red: 1.0, green: 0.72, blue: 0.3, alpha: 1)
    )

    static let stateError = dynamic(
        light: NSColor.systemRed,
        dark: NSColor(red: 1.0, green: 0.42, blue: 0.4, alpha: 1)
    )

    // MARK: - Speaker chips (6-stop ramp)

    private static let speakerRampLight: [NSColor] = [
        NSColor(red: 0.20, green: 0.47, blue: 0.95, alpha: 1),
        NSColor(red: 0.85, green: 0.35, blue: 0.55, alpha: 1),
        NSColor(red: 0.30, green: 0.68, blue: 0.55, alpha: 1),
        NSColor(red: 0.85, green: 0.55, blue: 0.20, alpha: 1),
        NSColor(red: 0.55, green: 0.40, blue: 0.85, alpha: 1),
        NSColor(red: 0.30, green: 0.62, blue: 0.80, alpha: 1),
    ]

    private static let speakerRampDark: [NSColor] = [
        NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1),
        NSColor(red: 0.95, green: 0.55, blue: 0.70, alpha: 1),
        NSColor(red: 0.45, green: 0.80, blue: 0.68, alpha: 1),
        NSColor(red: 0.95, green: 0.70, blue: 0.40, alpha: 1),
        NSColor(red: 0.70, green: 0.58, blue: 0.95, alpha: 1),
        NSColor(red: 0.48, green: 0.75, blue: 0.92, alpha: 1),
    ]

    /// Stable per-speaker chip color, 6-stop ramp, wraps for index >= 6.
    static func speakerChip(index: Int) -> Color {
        let i = ((index % speakerRampLight.count) + speakerRampLight.count) % speakerRampLight.count
        return Color(nsColor: dynamicRaw(light: speakerRampLight[i], dark: speakerRampDark[i]))
    }

    // MARK: - Helpers

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicRaw(light: light, dark: dark))
    }

    private static func dynamicRaw(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
