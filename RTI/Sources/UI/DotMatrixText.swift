import SwiftUI

/// Pixel/dot-matrix renderer for short numeric strings (timers, counters).
///
/// Intentionally tiny: 5×7 glyphs for digits, colon, dash, dot, and space —
/// just enough for `MM:SS`, durations, and integer counts. For anything
/// alphabetic, fall back to a system font; pixel rendering hurts readability
/// at body sizes and is reserved here for at-a-glance scoreboard moments.
struct DotMatrixText: View {
    let text: String
    var dot: CGFloat = 2
    var spacing: CGFloat = 1
    var gap: CGFloat = 1
    var color: Color = .white
    var dim: Color? = nil

    private static let glyphWidth = 5
    private static let glyphHeight = 7

    var body: some View {
        let chars = Array(text)
        let charW = CGFloat(Self.glyphWidth) * dot + CGFloat(Self.glyphWidth - 1) * spacing
        let charH = CGFloat(Self.glyphHeight) * dot + CGFloat(Self.glyphHeight - 1) * spacing
        let totalW = CGFloat(chars.count) * charW + CGFloat(max(0, chars.count - 1)) * gap

        Canvas { ctx, _ in
            for (i, ch) in chars.enumerated() {
                let originX = CGFloat(i) * (charW + gap)
                guard let rows = Self.glyph(for: ch) else { continue }
                for (r, row) in rows.enumerated() {
                    for c in 0..<Self.glyphWidth {
                        let bit = (row >> (Self.glyphWidth - 1 - c)) & 1
                        let x = originX + CGFloat(c) * (dot + spacing)
                        let y = CGFloat(r) * (dot + spacing)
                        let rect = CGRect(x: x, y: y, width: dot, height: dot)
                        if bit == 1 {
                            ctx.fill(Path(rect), with: .color(color))
                        } else if let dim {
                            ctx.fill(Path(rect), with: .color(dim))
                        }
                    }
                }
            }
        }
        .frame(width: totalW, height: charH)
    }

    /// 5×7 bitmap rows. Each Int is 5 low bits, MSB = leftmost pixel.
    private static func glyph(for ch: Character) -> [Int]? {
        switch ch {
        case "0": return [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110]
        case "1": return [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110]
        case "2": return [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111]
        case "3": return [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110]
        case "4": return [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010]
        case "5": return [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110]
        case "6": return [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110]
        case "7": return [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000]
        case "8": return [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110]
        case "9": return [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100]
        case ":": return [0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000]
        case ".": return [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100]
        case "-": return [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000]
        case " ": return [0, 0, 0, 0, 0, 0, 0]
        default:  return nil
        }
    }
}
