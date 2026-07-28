import AppKit
import SwiftUI

extension Color {
    static let overlayInk = Color(nsColor: NSColor(name: nil) { appearance in
        let contrast = OverlayThemeSettings.contrast
        if OverlayThemeSettings.isDark(appearance) {
            let white = min(1, 0.78 + contrast * 0.0028)
            return NSColor(white: white, alpha: 1)
        } else {
            let white = max(0, 0.20 - contrast * 0.0018)
            return NSColor(white: white, alpha: 1)
        }
    })

    static let overlayPanel = Color(nsColor: NSColor(name: nil) { appearance in
        if OverlayThemeSettings.isDark(appearance) {
            return NSColor(white: 0.095, alpha: 1)
        } else {
            return NSColor.white
        }
    })

    static let overlayInput = Color(nsColor: NSColor(name: nil) { appearance in
        if OverlayThemeSettings.isDark(appearance) {
            return NSColor(white: 0.15, alpha: 1)
        } else {
            return NSColor.white
        }
    })

    static let overlayBorder = Color(nsColor: NSColor(name: nil) { appearance in
        if OverlayThemeSettings.isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.12)
        } else {
            return NSColor.black.withAlphaComponent(0.08)
        }
    })

    static let overlayAccent = Color(nsColor: NSColor(name: nil) { _ in
        OverlayThemeSettings.accentColor
    })
}

enum OverlayThemeSettings {
    static var contrast: CGFloat {
        let value = UserDefaults.standard.double(forKey: OverlayAppearanceDefaults.contrastKey)
        let resolved = value > 0 ? value : OverlayAppearanceDefaults.defaultContrast
        return CGFloat(min(max(resolved, OverlayAppearanceDefaults.contrastRange.lowerBound),
                           OverlayAppearanceDefaults.contrastRange.upperBound))
    }

    static var accentColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: OverlayAppearanceDefaults.accentColorKey)
            ?? OverlayAppearanceDefaults.defaultAccentColor
        return NSColor.rtiColor(hex: hex) ?? NSColor.systemBlue
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
