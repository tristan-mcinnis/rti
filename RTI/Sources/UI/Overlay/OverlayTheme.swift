import AppKit
import SwiftUI
import HouseDesign
import RTICore

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

    /// contrast 35 → 0.84, 60 (default) → 1.0: the default is full ink, so
    /// text is near-black, not grey (2026-11-14 review).
    static func primaryAlpha(_ contrast: CGFloat) -> CGFloat {
        min(1.0, 0.616 + contrast * 0.0064)
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
