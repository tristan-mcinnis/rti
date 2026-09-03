// GENERATED from design-system/tokens.json 3f0480fd80d7; do not edit
// Source of truth: the design-system repo (DESIGN.md + tokens.json).
// Regenerate with `make swift` there; `make check` verifies this copy.

import AppKit
import SwiftUI

/// House design tokens. Semantic names only; colours adapt to the
/// window appearance (light / dark) without per-view code.
enum House {
    /// AppKit colours, one per token, resolved per appearance.
    enum NSColorToken {
        /// Window and panel ground.
        static let surface = adaptive(
            light: NSColor(srgbRed: 0.9686, green: 0.9686, blue: 0.9725, alpha: 1.0),
            dark: NSColor(srgbRed: 0.102, green: 0.1059, blue: 0.1176, alpha: 1.0)
        )
        /// Cards, inputs, and rows that sit above the ground.
        static let surfaceRaised = adaptive(
            light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            dark: NSColor(srgbRed: 0.149, green: 0.1569, blue: 0.1725, alpha: 1.0)
        )
        /// Tracks and wells that sit below the ground.
        static let surfaceSunken = adaptive(
            light: NSColor(srgbRed: 0.9255, green: 0.9255, blue: 0.9373, alpha: 1.0),
            dark: NSColor(srgbRed: 0.0784, green: 0.0824, blue: 0.0902, alpha: 1.0)
        )
        /// Quiet grouped surfaces painted over any ground.
        static let surfaceTint = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.035),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.055)
        )
        /// Body text and primary labels.
        static let textPrimary = adaptive(
            light: NSColor(srgbRed: 0.0667, green: 0.0667, blue: 0.0784, alpha: 1.0),
            dark: NSColor(srgbRed: 0.9412, green: 0.9412, blue: 0.949, alpha: 1.0)
        )
        /// Supporting text.
        static let textSecondary = adaptive(
            light: NSColor(srgbRed: 0.3451, green: 0.3451, blue: 0.3804, alpha: 1.0),
            dark: NSColor(srgbRed: 0.6588, green: 0.6588, blue: 0.6902, alpha: 1.0)
        )
        /// Metadata. Still 4.5:1 on surface.
        static let textTertiary = adaptive(
            light: NSColor(srgbRed: 0.4314, green: 0.4314, blue: 0.4627, alpha: 1.0),
            dark: NSColor(srgbRed: 0.549, green: 0.549, blue: 0.5804, alpha: 1.0)
        )
        /// Text on accent or on the HUD.
        static let textInverse = adaptive(
            light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.9608, alpha: 1.0),
            dark: NSColor(srgbRed: 0.0667, green: 0.0667, blue: 0.0784, alpha: 1.0)
        )
        /// The one accent. Primary action only.
        static let accent = adaptive(
            light: NSColor(srgbRed: 0.0314, green: 0.4, blue: 0.8392, alpha: 1.0),
            dark: NSColor(srgbRed: 0.3529, green: 0.6667, blue: 1.0, alpha: 1.0)
        )
        /// Tinted fill behind an accent label.
        static let accentSoft = adaptive(
            light: NSColor(srgbRed: 0.0314, green: 0.4, blue: 0.8392, alpha: 0.12),
            dark: NSColor(srgbRed: 0.3529, green: 0.6667, blue: 1.0, alpha: 0.18)
        )
        /// Status only.
        static let success = adaptive(
            light: NSColor(srgbRed: 0.1176, green: 0.5412, blue: 0.3059, alpha: 1.0),
            dark: NSColor(srgbRed: 0.298, green: 0.7647, blue: 0.5412, alpha: 1.0)
        )
        /// Status only.
        static let warning = adaptive(
            light: NSColor(srgbRed: 0.7216, green: 0.4627, blue: 0.0392, alpha: 1.0),
            dark: NSColor(srgbRed: 0.9608, green: 0.7216, blue: 0.2902, alpha: 1.0)
        )
        /// Status and destructive actions only.
        static let danger = adaptive(
            light: NSColor(srgbRed: 0.7529, green: 0.2235, blue: 0.1686, alpha: 1.0),
            dark: NSColor(srgbRed: 1.0, green: 0.4196, blue: 0.3686, alpha: 1.0)
        )
        /// Hairline around panels, cards, fields.
        static let stroke = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.1),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
        )
        /// Selected or focused hairline.
        static let strokeStrong = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.18),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22)
        )
        /// Highlighted row.
        static let selectionFill = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.07),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.1)
        )
        /// Hover and pressed feedback.
        static let hoverFill = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.075),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.1)
        )
        /// Key-cap background.
        static let keyCapFill = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.06),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.09)
        )
        /// Key-cap hairline.
        static let keyCapStroke = adaptive(
            light: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.1),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.12)
        )
        /// Tint over the blur material of a floating panel.
        static let panelTint = adaptive(
            light: NSColor(srgbRed: 0.9686, green: 0.9686, blue: 0.9725, alpha: 0.78),
            dark: NSColor(srgbRed: 0.1098, green: 0.1216, blue: 0.1412, alpha: 0.82)
        )
        /// Dark HUD pill or toast, same in both modes.
        static let hudFill = adaptive(
            light: NSColor(srgbRed: 0.0706, green: 0.0706, blue: 0.0784, alpha: 0.95),
            dark: NSColor(srgbRed: 0.0706, green: 0.0706, blue: 0.0784, alpha: 0.95)
        )
        /// Text on the HUD.
        static let hudText = adaptive(
            light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.9608, alpha: 1.0),
            dark: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.9608, alpha: 1.0)
        )
        /// Hairline on the HUD.
        static let hudStroke = adaptive(
            light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.1),
            dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.1)
        )
        /// Busy or idle marks on the HUD.
        static let hudMuted = adaptive(
            light: NSColor(srgbRed: 0.549, green: 0.5804, blue: 0.6196, alpha: 1.0),
            dark: NSColor(srgbRed: 0.549, green: 0.5804, blue: 0.6196, alpha: 1.0)
        )

        static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
    }

    /// SwiftUI colours wrapping `NSColorToken`.
    enum ColorToken {
        static let surface = Color(nsColor: NSColorToken.surface)
        static let surfaceRaised = Color(nsColor: NSColorToken.surfaceRaised)
        static let surfaceSunken = Color(nsColor: NSColorToken.surfaceSunken)
        static let surfaceTint = Color(nsColor: NSColorToken.surfaceTint)
        static let textPrimary = Color(nsColor: NSColorToken.textPrimary)
        static let textSecondary = Color(nsColor: NSColorToken.textSecondary)
        static let textTertiary = Color(nsColor: NSColorToken.textTertiary)
        static let textInverse = Color(nsColor: NSColorToken.textInverse)
        static let accent = Color(nsColor: NSColorToken.accent)
        static let accentSoft = Color(nsColor: NSColorToken.accentSoft)
        static let success = Color(nsColor: NSColorToken.success)
        static let warning = Color(nsColor: NSColorToken.warning)
        static let danger = Color(nsColor: NSColorToken.danger)
        static let stroke = Color(nsColor: NSColorToken.stroke)
        static let strokeStrong = Color(nsColor: NSColorToken.strokeStrong)
        static let selectionFill = Color(nsColor: NSColorToken.selectionFill)
        static let hoverFill = Color(nsColor: NSColorToken.hoverFill)
        static let keyCapFill = Color(nsColor: NSColorToken.keyCapFill)
        static let keyCapStroke = Color(nsColor: NSColorToken.keyCapStroke)
        static let panelTint = Color(nsColor: NSColorToken.panelTint)
        static let hudFill = Color(nsColor: NSColorToken.hudFill)
        static let hudText = Color(nsColor: NSColorToken.hudText)
        static let hudStroke = Color(nsColor: NSColorToken.hudStroke)
        static let hudMuted = Color(nsColor: NSColorToken.hudMuted)
    }

    /// Type scale: SF system font, fixed point sizes.
    enum TypeToken {
        static let display = Font.system(size: 28.0, weight: .semibold)
        static let title = Font.system(size: 20.0, weight: .semibold)
        static let heading = Font.system(size: 16.0, weight: .semibold)
        static let body = Font.system(size: 14.0, weight: .regular)
        static let bodySmall = Font.system(size: 13.0, weight: .regular)
        static let label = Font.system(size: 13.0, weight: .medium)
        static let meta = Font.system(size: 12.0, weight: .regular)
        static let caption = Font.system(size: 11.0, weight: .regular)
        static let micro = Font.system(size: 10.0, weight: .regular)
        static let keyCap = Font.system(size: 10.0, weight: .medium, design: .monospaced)
        static let code = Font.system(size: 12.0, weight: .regular, design: .monospaced)

        /// Point sizes, for views that scale type manually.
        enum Size {
            static let display: CGFloat = 28.0
            static let title: CGFloat = 20.0
            static let heading: CGFloat = 16.0
            static let body: CGFloat = 14.0
            static let bodySmall: CGFloat = 13.0
            static let label: CGFloat = 13.0
            static let meta: CGFloat = 12.0
            static let caption: CGFloat = 11.0
            static let micro: CGFloat = 10.0
            static let keyCap: CGFloat = 10.0
            static let code: CGFloat = 12.0
        }
    }

    enum Radius {
        static let xs: CGFloat = 4.0
        static let sm: CGFloat = 6.0
        static let md: CGFloat = 8.0
        static let lg: CGFloat = 12.0
        static let xl: CGFloat = 16.0
        static let xxl: CGFloat = 24.0
    }

    enum Spacing {
        static let xxs: CGFloat = 4.0
        static let xs: CGFloat = 8.0
        static let sm: CGFloat = 12.0
        static let md: CGFloat = 16.0
        static let lg: CGFloat = 20.0
        static let xl: CGFloat = 24.0
        static let xxl: CGFloat = 32.0
        static let xxxl: CGFloat = 48.0
        static let xxxxl: CGFloat = 64.0
    }

    enum Control {
        static let compact: CGFloat = 28.0
        static let small: CGFloat = 32.0
        static let medium: CGFloat = 40.0
        static let large: CGFloat = 44.0
        static let xlarge: CGFloat = 48.0
        static let hero: CGFloat = 56.0
    }

    enum Motion {
        static let fast: TimeInterval = 0.1
        static let normal: TimeInterval = 0.2
    }

    static let hairline: CGFloat = 1.0
}
