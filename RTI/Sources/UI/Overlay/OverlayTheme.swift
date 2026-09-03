import AppKit
import SwiftUI

// The overlay's colour vocabulary. Every entry is a house token
// (HouseDesign.swift); the only local behaviour is the user's contrast
// slider, which modulates the ink's alpha exactly as the design rule says
// ("text tiers are ink at reduced alpha, so they track any ground").

extension Color {
    /// Primary ink. Warm near-white on dark, warm near-black on light, at the
    /// alpha the contrast slider asks for.
    static let overlayInk = Color(nsColor: OverlayInk.nsColor(tier: .primary))
    /// Ink at ~60 % (dark) / 62 % (light). Supporting text.
    static let overlayInkSecondary = Color(nsColor: OverlayInk.nsColor(tier: .secondary))
    /// Ink at ~40 % (dark) / 50 % (light). Metadata, placeholders.
    static let overlayInkTertiary = Color(nsColor: OverlayInk.nsColor(tier: .tertiary))
    /// Text on an ink-filled control (the composer's send tile).
    static let overlayInkInverse = House.ColorToken.textInverse

    // Grounds and hairlines.
    static let overlayPanel = House.ColorToken.surface
    static let overlayPanelTint = House.ColorToken.panelTint
    static let overlayInput = House.ColorToken.surfaceRaised
    static let overlaySunken = House.ColorToken.surfaceSunken
    static let overlayWell = House.ColorToken.well
    static let overlayBorder = House.ColorToken.stroke
    static let overlayBorderStrong = House.ColorToken.strokeStrong
    static let overlayDivider = House.ColorToken.divider
    static let overlayHighlightTop = House.ColorToken.highlightTop

    // Quiet fills.
    static let overlayChipFill = House.ColorToken.chipFill
    static let overlayTileFill = House.ColorToken.tileFill
    static let overlayHoverFill = House.ColorToken.hoverFill
    static let overlaySelectionFill = House.ColorToken.selectionFill

    // Status. The only chroma the chrome is allowed.
    static let overlaySuccess = House.ColorToken.success
    static let overlayWarning = House.ColorToken.warning
    static let overlayDanger = House.ColorToken.danger

    /// Focus rings and links only — never a chrome fill, never a tab tint.
    /// (The old user-picked accent no longer paints chrome; see DESIGN.md.)
    static let overlayAccent = House.ColorToken.accent
}

/// The ink ramp. Base RGB is the house `textPrimary`; the contrast slider
/// scales the primary alpha, and the secondary / tertiary tiers stay in fixed
/// proportion to it so they track any ground.
enum OverlayInk {
    enum Tier {
        case primary, secondary, tertiary

        /// Fraction of the primary alpha, per appearance (DESIGN.md § 5).
        func factor(dark: Bool) -> CGFloat {
            switch self {
            case .primary: 1.0
            case .secondary: dark ? 0.60 : 0.62
            case .tertiary: dark ? 0.40 : 0.50
            }
        }
    }

    static func nsColor(tier: Tier) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = OverlayThemeSettings.isDark(appearance)
            let base = House.NSColorToken.textPrimary.resolved(for: appearance)
            let alpha = primaryAlpha(OverlayThemeSettings.contrast) * tier.factor(dark: dark)
            return base.withAlphaComponent(min(1, max(0, alpha)))
        }
    }

    /// contrast 35 → 0.74, 60 (default) → 0.90, 85 → 1.0.
    static func primaryAlpha(_ contrast: CGFloat) -> CGFloat {
        min(1.0, 0.52 + contrast * 0.0064)
    }
}

private extension NSColor {
    /// Resolve a dynamic NSColor for one appearance without touching the
    /// process-wide current appearance.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance {
            out = (self.usingColorSpace(.sRGB) ?? self)
        }
        return out
    }
}

enum OverlayThemeSettings {
    static var contrast: CGFloat {
        let value = UserDefaults.standard.double(forKey: OverlayAppearanceDefaults.contrastKey)
        let resolved = value > 0 ? value : OverlayAppearanceDefaults.defaultContrast
        return CGFloat(min(max(resolved, OverlayAppearanceDefaults.contrastRange.lowerBound),
                           OverlayAppearanceDefaults.contrastRange.upperBound))
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    static func rtiColor(hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var rtiHexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
