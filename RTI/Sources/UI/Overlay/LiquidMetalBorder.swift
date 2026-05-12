import SwiftUI

/// Animated chromatic border — a conic gradient rotates around the shape so the
/// stroke shimmers with an iridescent liquid-metal sheen. Inspired by
/// https://metal.jakubantalik.com.
struct LiquidMetalBorder<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat = 1.2
    var period: Double = 4.0
    var glow: CGFloat = 6

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(t.truncatingRemainder(dividingBy: period) / period * 360.0)

            ZStack {
                // Soft outer halo so the chromatic edge bleeds onto the dark panel.
                shape
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: Self.haloPalette),
                            center: .center,
                            angle: angle
                        ),
                        lineWidth: lineWidth + 1.5
                    )
                    .blur(radius: glow)
                    .opacity(0.85)

                // Crisp chromatic stroke.
                shape
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: Self.edgePalette),
                            center: .center,
                            angle: angle
                        ),
                        lineWidth: lineWidth
                    )
            }
            .allowsHitTesting(false)
        }
    }

    private static var edgePalette: [Color] {
        [
            Color(red: 1.00, green: 1.00, blue: 1.00),
            Color(red: 0.55, green: 0.85, blue: 1.00), // cyan
            Color(red: 0.85, green: 0.60, blue: 1.00), // violet
            Color(red: 1.00, green: 0.65, blue: 0.85), // pink
            Color(red: 1.00, green: 0.92, blue: 0.65), // warm gold
            Color(red: 0.65, green: 1.00, blue: 0.90), // mint
            Color(red: 1.00, green: 1.00, blue: 1.00)
        ]
    }

    private static var haloPalette: [Color] {
        [
            Color.white.opacity(0.0),
            Color(red: 0.55, green: 0.85, blue: 1.00).opacity(0.55),
            Color(red: 0.85, green: 0.60, blue: 1.00).opacity(0.55),
            Color(red: 1.00, green: 0.65, blue: 0.85).opacity(0.55),
            Color(red: 1.00, green: 0.92, blue: 0.65).opacity(0.55),
            Color(red: 0.65, green: 1.00, blue: 0.90).opacity(0.55),
            Color.white.opacity(0.0)
        ]
    }
}

extension View {
    /// Overlay an animated liquid-metal chromatic border on a primary action.
    func liquidMetalBorder<S: InsettableShape>(
        _ shape: S,
        lineWidth: CGFloat = 1.2,
        period: Double = 4.0,
        glow: CGFloat = 6,
        active: Bool = true
    ) -> some View {
        overlay(
            Group {
                if active {
                    LiquidMetalBorder(shape: shape, lineWidth: lineWidth, period: period, glow: glow)
                }
            }
        )
    }
}
