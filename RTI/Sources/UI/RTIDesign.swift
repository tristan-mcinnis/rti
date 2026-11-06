import AppKit
import SwiftUI
import HouseDesign
import RTICore

/// RTI's view of the house design system ("Slate", direction 1b).
///
/// Every value comes from the generated `HouseDesign.swift`
/// (design-system/tokens.json). Nothing is retyped here. The only local
/// addition is the six-colour speaker palette, which DESIGN.md sanctions as
/// data colour, not chrome.
///
/// The aliases below are the migration surface: existing views call
/// `RTIDesign.Color.textSecondary` / `RTIDesign.Radius.md` and land on house
/// tokens. The `Slate*` components underneath are the shapes the mockups
/// actually draw — chips, tiles, cards, wells, ink toggles.
enum RTIDesign {
    // MARK: - Color

    enum Color {
        static let appBackground = House.ColorToken.surface
        static let trackBackground = House.ColorToken.surfaceSunken
        static let cardBackground = House.ColorToken.surfaceRaised

        /// Quiet grouped fill painted over any ground (settings card body).
        static let groupedFill = House.ColorToken.surfaceTint
        /// Sunken footer / rail well.
        static let well = House.ColorToken.well
        static let chipFill = House.ColorToken.chipFill
        static let tileFill = House.ColorToken.tileFill
        static let tileStroke = House.ColorToken.tileStroke

        static let border = House.ColorToken.stroke
        static let borderStrong = House.ColorToken.strokeStrong
        static let divider = House.ColorToken.divider
        static let highlightTop = House.ColorToken.highlightTop

        static let selectionFill = House.ColorToken.selectionFill
        static let selectionRing = House.ColorToken.selectionRing
        static let hoverFill = House.ColorToken.hoverFill

        static let keyCapFill = House.ColorToken.keyCapFill
        static let keyCapStroke = House.ColorToken.keyCapStroke

        static let textPrimary = House.ColorToken.textPrimary
        static let textSecondary = House.ColorToken.textSecondary
        static let textTertiary = House.ColorToken.textTertiary
        static let textInverse = House.ColorToken.textInverse

        /// Focus rings and links only. Never a chrome fill, never a tab tint.
        static let accent = House.ColorToken.accent
        static let accentText = House.ColorToken.accent

        static let success = House.ColorToken.success
        static let warning = House.ColorToken.warning
        static let danger = House.ColorToken.danger

        // Speaker chip palette — the one allowed categorical palette (DESIGN.md).
        // Indexed by trailing digit so Speaker 1 / 2 / 3 are stable across sessions.
        // Each hue has a lighter dark-appearance tint, so a speaker's name
        // stays readable as text on the dark ground, not only as a dot.
        static let speakerPalette: [SwiftUI.Color] = [
            speaker(light: (0.024, 0.463, 0.847), dark: (0.392, 0.667, 1.000)), // blue (self/0)
            speaker(light: (0.847, 0.314, 0.235), dark: (1.000, 0.494, 0.431)), // red
            speaker(light: (0.196, 0.604, 0.380), dark: (0.384, 0.804, 0.541)), // green
            speaker(light: (0.580, 0.341, 0.737), dark: (0.780, 0.580, 0.949)), // purple
            speaker(light: (0.890, 0.553, 0.110), dark: (1.000, 0.718, 0.322)), // amber
            speaker(light: (0.180, 0.522, 0.620), dark: (0.400, 0.765, 0.859)), // teal
        ]

        private static func speaker(
            light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            })
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs = House.Spacing.xxs   // 4
        static let xs = House.Spacing.xs     // 8
        static let sm = House.Spacing.sm     // 12
        static let md = House.Spacing.md     // 16
        static let lg = House.Spacing.lg     // 20
        static let xl = House.Spacing.xl     // 24
        static let xxl = House.Spacing.xxl   // 32
        static let xxxl = House.Spacing.xxxl // 48
    }

    // MARK: - Radius

    enum Radius {
        static let xs = House.Radius.xs      // 5  key caps
        static let chip = House.Radius.sm    // 6  chips, fields
        static let tile = House.Radius.tile  // 7  icon tiles
        static let sm = House.Radius.md      // 8  menus, tab tiles
        static let row = House.Radius.row    // 10 rows
        static let md = House.Radius.lg      // 12 cards
        static let lg = House.Radius.xl      // 16 panels
        static let xl = House.Radius.xxl     // 24
    }

    // MARK: - Font

    enum Font {
        static let heading = House.TypeToken.heading
        static let input = House.TypeToken.input
        static let body = House.TypeToken.body
        static let bodySmall = House.TypeToken.bodySmall
        static let label = House.TypeToken.label
        static let meta = House.TypeToken.meta
        static let caption = House.TypeToken.caption
        static let micro = House.TypeToken.micro
        static let section = House.TypeToken.section
        static let keyCap = House.TypeToken.keyCap
        static let code = House.TypeToken.code
        static let button = House.TypeToken.label
        /// Tab tiles carry a medium label, not a semibold one.
        static let tab = SwiftUI.Font.system(size: House.TypeToken.Size.meta, weight: .medium)
    }

    // MARK: - Controls

    enum Control {
        static let keyCap = House.Control.keyCap        // 20
        static let tile = House.Control.tile            // 26
        static let chip = House.Control.chip            // 28
        static let railRow = House.Control.railRow      // 36
        static let footer = House.Control.footer        // 40
        static let sessionRow = House.Control.sessionRow // 44
        static let composer = House.Control.composer    // 52
        static let composerHeight = House.Control.composer
    }

    // MARK: - Layout

    enum Layout {
        static let answerMaxWidth = House.Layout.answerMaxWidth   // 620
        static let settingsRail = House.Layout.settingsRail       // 220
    }

    // MARK: - Density

    enum Density: String, CaseIterable {
        case comfortable
        case compact

        /// Scale a comfortable-mode value down for compact mode.
        /// Used for inter-section spacing, line spacing, and group padding.
        func scaled(_ value: CGFloat) -> CGFloat {
            switch self {
            case .comfortable: return value
            case .compact:     return value * 0.66
            }
        }

        static var current: Density {
            let raw = UserDefaults.standard.string(forKey: UISettingsDefaults.sessionDetailDensityKey) ?? Density.comfortable.rawValue
            return Density(rawValue: raw) ?? .comfortable
        }
    }
}

// MARK: - Line spacing helpers

extension RTIDesign.Font {
    /// SwiftUI `lineSpacing` is the GAP between lines, not the line height, so
    /// the house line-height multiples convert to `size * (multiple - 1)`.
    static let bodySmallLineSpacing: CGFloat =
        House.TypeToken.Size.bodySmall * (House.TypeToken.LineHeight.bodySmall - 1)
}

// MARK: - Shadows

extension View {
    /// The drop under a raised card or composer.
    func slateCardShadow(_ scheme: ColorScheme) -> some View {
        shadow(
            color: .black.opacity(House.Shadow.card.opacity(dark: scheme == .dark)),
            radius: House.Shadow.card.blur / 2,
            y: House.Shadow.card.y
        )
    }

    /// The 1 pt drop under a selected row.
    func slateSelectionShadow(_ scheme: ColorScheme, active: Bool = true) -> some View {
        shadow(
            color: .black.opacity(active ? House.Shadow.selection.opacity(dark: scheme == .dark) : 0),
            radius: House.Shadow.selection.blur / 2,
            y: House.Shadow.selection.y
        )
    }
}

// MARK: - Glass

/// The blur material behind `panelTint` on every floating RTI surface.
/// `.behindWindow` blending needs the hosting window to be non-opaque with a
/// clear background; `OverlayWindowController` sets that up.
struct SlateVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}

/// Offscreen render proof only: `.behindWindow` blur has no desktop to sample
/// in a headless bitmap, so the harness flattens the material to the opaque
/// `surface` token, which is what the blur + `panelTint` resolve to anyway.
enum SlateRenderMode {
    nonisolated(unsafe) static var flattenGlass = false
}

extension RTIDesign.Color {
    static let panelTint = House.ColorToken.panelTint
}

// MARK: - Status dot

/// Never colour alone: every caller pairs the dot with a word (DESIGN.md).
struct SlateStatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Chip

/// 28 high at `Radius.sm`, `chipFill`, `meta` text. The one piece of chroma a
/// chip may carry is a status dot.
struct SlateChip<Content: View>: View {
    var height: CGFloat = RTIDesign.Control.chip
    var stroked = true
    var emphasised = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xxs + 2) {
            content
        }
        .font(RTIDesign.Font.meta)
        .foregroundStyle(emphasised ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
        .padding(.horizontal, height <= RTIDesign.Control.tile ? 8 : 9)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                .fill(emphasised ? RTIDesign.Color.selectionFill : RTIDesign.Color.chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                .strokeBorder(stroked ? RTIDesign.Color.border : Color.clear, lineWidth: House.hairline)
        )
    }
}

// MARK: - Footer well

/// 40 high, painted as a `well` with a top divider: status dot + context on
/// the left, key hints on the right. Shared by the overlay, Settings, and the
/// sessions browser so all three read as one app.
struct SlateFooter<Trailing: View>: View {
    let statusColor: Color?
    let status: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xs + 2) {
            if let statusColor {
                SlateStatusDot(color: statusColor)
            }
            Text(status)
                .font(RTIDesign.Font.meta)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: RTIDesign.Spacing.xs)
            trailing
                .layoutPriority(1)
        }
        .padding(.leading, RTIDesign.Spacing.md)
        .padding(.trailing, RTIDesign.Spacing.sm)
        .frame(height: RTIDesign.Control.footer)
        .frame(maxWidth: .infinity)
        .background(RTIDesign.Color.well)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(height: House.hairline)
        }
    }
}

// MARK: - Icon tile

/// A row glyph in a 26 px tile so rows align whatever the symbol width.
struct SlateIconTile: View {
    let systemName: String
    var size: CGFloat = RTIDesign.Control.tile
    var glyphSize: CGFloat = 13
    var filled = true

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .regular))
            .foregroundStyle(RTIDesign.Color.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.tile, style: .continuous)
                    .fill(filled ? RTIDesign.Color.tileFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.tile, style: .continuous)
                    .strokeBorder(filled ? RTIDesign.Color.tileStroke : Color.clear, lineWidth: House.hairline)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Section label

/// "SUGGESTIONS", "TODAY": 10.5 semibold, uppercase, tracked.
struct SlateSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(RTIDesign.Font.section)
            .tracking(House.TypeToken.Tracking.section)
            .foregroundStyle(RTIDesign.Color.textTertiary)
            .accessibilityLabel(text)
    }
}

// MARK: - Raised tile / selection

extension View {
    /// A raised tile: the selected tab, the selected rail row, the selected
    /// session. Fill plus an inset ring plus a 1 px drop — never an accent.
    func slateRaisedTile(_ selected: Bool, cornerRadius: CGFloat = RTIDesign.Radius.sm, hovering: Bool = false) -> some View {
        modifier(SlateRaisedTile(selected: selected, cornerRadius: cornerRadius, hovering: hovering))
    }

    /// A raised card: `surfaceRaised` at `Radius.lg`, hairline, top highlight,
    /// card shadow. The composer and every Settings group use it.
    func slateRaisedCard(cornerRadius: CGFloat = RTIDesign.Radius.md) -> some View {
        modifier(SlateRaisedCard(cornerRadius: cornerRadius))
    }

    /// A quiet grouped card painted over the ground (Settings groups).
    func slateGroupCard(cornerRadius: CGFloat = RTIDesign.Radius.md) -> some View {
        modifier(SlateGroupCard(cornerRadius: cornerRadius))
    }
}

private struct SlateRaisedTile: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected
                          ? RTIDesign.Color.selectionFill
                          : (hovering ? RTIDesign.Color.hoverFill : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(selected ? RTIDesign.Color.selectionRing : Color.clear,
                                          lineWidth: House.hairline)
                    )
                    .slateSelectionShadow(scheme, active: selected)
            )
    }
}

private struct SlateRaisedCard: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RTIDesign.Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(RTIDesign.Color.border, lineWidth: House.hairline)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(RTIDesign.Color.highlightTop)
                            .frame(height: House.hairline)
                            .padding(.horizontal, cornerRadius / 2)
                    }
                    .slateCardShadow(scheme)
            )
    }
}

private struct SlateGroupCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RTIDesign.Color.groupedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(RTIDesign.Color.border, lineWidth: House.hairline)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(RTIDesign.Color.highlightTop)
                            .frame(height: House.hairline)
                            .padding(.horizontal, cornerRadius / 2)
                    }
            )
    }
}

// MARK: - Ink toggle

/// Toggles are ink, never blue: an on toggle is a `textPrimary` track with a
/// `textInverse` knob; an off toggle is an outline with a tertiary knob.
struct SlateToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: RTIDesign.Spacing.xs) {
                configuration.label
                    .font(RTIDesign.Font.label)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer(minLength: RTIDesign.Spacing.xs)
                track(configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func track(_ isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? RTIDesign.Color.textPrimary : Color.clear)
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? Color.clear : RTIDesign.Color.keyCapStroke,
                        lineWidth: House.hairline
                    )
                )
                .frame(width: 30, height: 18)
            Circle()
                .fill(isOn ? RTIDesign.Color.textInverse : RTIDesign.Color.textTertiary)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 2)
        }
        .frame(width: 30, height: 18)
        .animation(.easeOut(duration: House.Motion.select), value: isOn)
    }
}

// MARK: - View Extensions

extension View {
    /// Caps content at a comfortable reading width and centers it. Used on
    /// text-stream tabs (Q&A) and the wider Transcript tab.
    func readingWidth(_ maxWidth: CGFloat = 720) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            self.frame(maxWidth: maxWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    /// House answer measure: 620 pt, left aligned.
    func answerWidth() -> some View {
        frame(maxWidth: RTIDesign.Layout.answerMaxWidth, alignment: .leading)
    }
}
