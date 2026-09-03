import AppKit
import SwiftUI

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
/// actually draw — chips, key caps, tiles, cards, wells, ink toggles.
enum RTIDesign {
    // MARK: - Color

    enum Color {
        static let appBackground = House.ColorToken.surface
        static let panelBackground = House.ColorToken.surface
        static let trackBackground = House.ColorToken.surfaceSunken
        static let cardBackground = House.ColorToken.surfaceRaised
        static let inputBackground = House.ColorToken.surfaceRaised

        /// Quiet grouped fill painted over any ground (settings card body).
        static let groupedFill = House.ColorToken.surfaceTint
        /// Sunken footer / rail well.
        static let well = House.ColorToken.well
        static let chipFill = House.ColorToken.chipFill
        static let tileFill = House.ColorToken.tileFill
        static let tileStroke = House.ColorToken.tileStroke

        static let border = House.ColorToken.stroke
        static let borderLight = House.ColorToken.stroke
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
        static let accentBg = House.ColorToken.accentSoft

        static let success = House.ColorToken.success
        static let warning = House.ColorToken.warning
        static let danger = House.ColorToken.danger

        /// Chips no longer take an accent tint; "active" is a raised tile.
        static let chipActiveBg = House.ColorToken.selectionFill
        static let chipActiveText = House.ColorToken.textPrimary

        // Soft tinted card for AI/assistant outputs (Summary blocks, Q&A turns).
        static let aiCardBackground = House.ColorToken.surfaceTint
        static let aiCardBorder = House.ColorToken.stroke

        // Toast (top-right pill) — the HUD tokens, identical in both modes.
        static let toastBackground = House.ColorToken.hudFill
        static let toastText = House.ColorToken.hudText

        // Speaker chip palette — the one allowed categorical palette (DESIGN.md).
        // Indexed by trailing digit so Speaker 1 / 2 / 3 are stable across sessions.
        static let speakerPalette: [SwiftUI.Color] = [
            SwiftUI.Color(red: 0.024, green: 0.463, blue: 0.847), // blue (self/0)
            SwiftUI.Color(red: 0.847, green: 0.314, blue: 0.235), // red
            SwiftUI.Color(red: 0.196, green: 0.604, blue: 0.380), // green
            SwiftUI.Color(red: 0.580, green: 0.341, blue: 0.737), // purple
            SwiftUI.Color(red: 0.890, green: 0.553, blue: 0.110), // amber
            SwiftUI.Color(red: 0.180, green: 0.522, blue: 0.620)  // teal
        ]
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs = House.Spacing.xxs   // 4
        static let xs = House.Spacing.xs     // 8
        static let sm = House.Spacing.sm     // 12
        static let md = House.Spacing.md     // 16
        static let lg = House.Spacing.xl     // 24
        static let xl = House.Spacing.xxl    // 32
        static let xxl = House.Spacing.xxxl  // 48
        static let xxxl = House.Spacing.xxxxl // 64
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
        static let pageTitle = House.TypeToken.display
        static let sectionTitle = House.TypeToken.title
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
        static let heightSm = House.Control.small       // 32
        static let railRow = House.Control.railRow      // 36
        static let heightMd = House.Control.medium      // 40
        static let footer = House.Control.footer        // 40
        static let sessionRow = House.Control.sessionRow // 44
        static let heightLg = House.Control.xlarge      // 48
        static let composer = House.Control.composer    // 52
        static let heightXl = House.Control.hero        // 56

        static let segTrackHeight = House.Control.medium
        static let segItemHeight = House.Control.chip

        static let composerHeight = House.Control.composer
        /// Square ink send tile inside the composer.
        static let composerSendSize = House.Control.chip
    }

    // MARK: - Layout

    enum Layout {
        static let answerMaxWidth = House.Layout.answerMaxWidth   // 620
        static let settingsRail = House.Layout.settingsRail       // 220
        static let sessionsRail: CGFloat = 250
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
    static let bodyLineSpacing: CGFloat =
        House.TypeToken.Size.body * (House.TypeToken.LineHeight.body - 1)
    static let bodySmallLineSpacing: CGFloat =
        House.TypeToken.Size.bodySmall * (House.TypeToken.LineHeight.bodySmall - 1)
}

// MARK: - Shadows

extension View {
    /// The two shadows under every floating panel.
    func slatePanelShadow(_ scheme: ColorScheme) -> some View {
        let dark = scheme == .dark
        return shadow(
            color: .black.opacity(House.Shadow.panelNear.opacity(dark: dark)),
            radius: House.Shadow.panelNear.blur / 2,
            y: House.Shadow.panelNear.y
        )
        .shadow(
            color: .black.opacity(House.Shadow.panelFar.opacity(dark: dark)),
            radius: House.Shadow.panelFar.blur / 2,
            y: House.Shadow.panelFar.y
        )
    }

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

/// The panel ground: blur material, `panelTint`, and a 1 px top highlight.
/// Used as the content background of the overlay and every RTI window, so all
/// of them read as the same glass.
struct SlateGlassBackground: View {
    /// Rounded panels (popovers, the palette) pass a radius; a window's own
    /// chrome supplies the corners, so it passes 0.
    var cornerRadius: CGFloat = 0
    var stroked = false

    var body: some View {
        ZStack {
            if SlateRenderMode.flattenGlass {
                RTIDesign.Color.appBackground
            } else {
                SlateVisualEffect()
                RTIDesign.Color.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RTIDesign.Color.highlightTop)
                .frame(height: House.hairline)
        }
        .overlay {
            if stroked {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RTIDesign.Color.border, lineWidth: House.hairline)
            }
        }
    }
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

/// An outlined chip: no fill, hairline outline. Used for speaker labels and
/// for secondary toggles that must not read as filled buttons.
struct SlateOutlineChip<Content: View>: View {
    var height: CGFloat = RTIDesign.Control.keyCap
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xxs + 2) {
            content
        }
        .font(RTIDesign.Font.caption)
        .foregroundStyle(RTIDesign.Color.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.xs, style: .continuous)
                .strokeBorder(RTIDesign.Color.borderStrong, lineWidth: House.hairline)
        )
    }
}

// MARK: - Key caps

/// One outlined key cap: 20 px tall, `keyCapStroke`, no fill, SF 11 medium.
struct SlateKeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(RTIDesign.Font.keyCap)
            .foregroundStyle(RTIDesign.Color.textSecondary)
            .frame(minWidth: RTIDesign.Control.keyCap, maxHeight: RTIDesign.Control.keyCap)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.xs, style: .continuous)
                    .fill(RTIDesign.Color.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.xs, style: .continuous)
                    .strokeBorder(RTIDesign.Color.keyCapStroke, lineWidth: House.hairline)
            )
            .accessibilityHidden(true)
    }
}

/// A labelled shortcut: "Assist ⌘ ↩". `keys` are already display glyphs.
struct SlateKeyHint: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xxs + 2) {
            Text(label)
                .font(RTIDesign.Font.meta)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            HStack(spacing: RTIDesign.Spacing.xxs) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    SlateKeyCap(symbol: key)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, RTIDesign.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(keys.joined())")
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
    func rtiCardStyle() -> some View {
        self
            .padding(RTIDesign.Spacing.md)
            .slateRaisedCard()
    }

    func rtiSoftTabStyle<SelectionValue: Hashable>(selection: Binding<SelectionValue>) -> some View {
        self
            .pickerStyle(.segmented)
            .labelsHidden()
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.sm, style: .continuous)
                    .fill(RTIDesign.Color.trackBackground)
                    .frame(height: RTIDesign.Control.segTrackHeight)
            )
    }

    /// Caps content at a comfortable reading width and centers it. Used on
    /// text-stream tabs (Summary, Q&A) and the wider Transcript tab.
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

// MARK: - Custom Segmented Picker

/// Slate segmented control: the selected item is a raised tile, not a tint.
struct RTISegmentedPicker<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let items: [T]
    @FocusState private var focusedItem: T?

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xxs - 1) {
            ForEach(items, id: \.self) { item in
                Button(action: { selection = item }) {
                    Text(item.description)
                        .font(RTIDesign.Font.tab)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selection == item ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, RTIDesign.Spacing.sm)
                        .frame(height: RTIDesign.Control.segItemHeight)
                        .slateRaisedTile(selection == item)
                        .overlay(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm, style: .continuous)
                                .strokeBorder(RTIDesign.Color.accent, lineWidth: 2)
                                .opacity(focusedItem == item ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focused($focusedItem, equals: item)
                .focusEffectDisabled()
            }
        }
        .padding(RTIDesign.Spacing.xxs)
        .frame(height: RTIDesign.Control.segTrackHeight)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.row, style: .continuous)
                .fill(RTIDesign.Color.well)
        )
    }
}
