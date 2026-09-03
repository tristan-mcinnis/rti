import SwiftUI

enum RTIDesign {
    // Values come from the generated HouseDesign.swift (design-system/tokens.json).
    // Only the speaker palette (data, not chrome) is local to RTI.

    // MARK: - Color
    enum Color {
        static let appBackground = House.ColorToken.surface
        static let panelBackground = House.ColorToken.surface
        static let trackBackground = House.ColorToken.surfaceSunken
        static let cardBackground = House.ColorToken.surfaceRaised
        static let inputBackground = House.ColorToken.surfaceRaised

        static let border = House.ColorToken.stroke
        static let borderLight = House.ColorToken.stroke
        static let borderStrong = House.ColorToken.strokeStrong
        static let divider = border.opacity(0.6)

        static let textPrimary = House.ColorToken.textPrimary
        static let textSecondary = House.ColorToken.textSecondary
        static let textTertiary = House.ColorToken.textTertiary

        static let accent = House.ColorToken.accent
        static let accentText = House.ColorToken.accent
        static let accentBg = House.ColorToken.accentSoft

        static let chipActiveBg = accentBg
        static let chipActiveText = House.ColorToken.accent

        // Soft tinted card for AI/assistant outputs (Summary blocks, Q&A assistant turns).
        static let aiCardBackground = House.ColorToken.surfaceTint
        static let aiCardBorder = House.ColorToken.stroke

        // Toast (top-right pill).
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
        static let xxs = House.Spacing.xxs
        static let xs = House.Spacing.xs
        static let sm = House.Spacing.sm
        static let md = House.Spacing.md
        static let lg = House.Spacing.xl
        static let xl = House.Spacing.xxl
        static let xxl = House.Spacing.xxxl
        static let xxxl = House.Spacing.xxxxl
    }

    // MARK: - Radius
    enum Radius {
        static let sm = House.Radius.md
        static let md = House.Radius.lg
        static let lg = House.Radius.xl
        static let xl = House.Radius.xxl
    }

    // MARK: - Font
    enum Font {
        static let pageTitle = House.TypeToken.display
        static let sectionTitle = House.TypeToken.title
        static let heading = House.TypeToken.heading
        static let body = House.TypeToken.body
        static let bodySmall = House.TypeToken.bodySmall
        static let meta = House.TypeToken.meta
        static let caption = House.TypeToken.caption
        static let button = House.TypeToken.label
        static let tab = SwiftUI.Font.system(size: House.TypeToken.Size.label, weight: .semibold)
    }

    // MARK: - Controls
    enum Control {
        static let heightSm = House.Control.small
        static let heightMd = House.Control.medium
        static let heightLg = House.Control.xlarge
        static let heightXl = House.Control.hero

        static let segTrackHeight = House.Control.medium
        static let segItemHeight = House.Control.small

        static let composerHeight = House.Control.hero
        static let composerSendSize = House.Control.large
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

// MARK: - View Extensions

extension View {
    func rtiCardStyle() -> some View {
        self
            .padding(RTIDesign.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                    .fill(RTIDesign.Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                            .stroke(RTIDesign.Color.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            )
    }

    func rtiSoftTabStyle<SelectionValue: Hashable>(selection: Binding<SelectionValue>) -> some View {
        self
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(.white.opacity(0.01))
            .scaleEffect(1, anchor: .center)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.lg)
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
}

// MARK: - Custom Segmented Picker

struct RTISegmentedPicker<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let items: [T]
    @FocusState private var focusedItem: T?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button(action: { selection = item }) {
                    Text(item.description)
                        .font(RTIDesign.Font.tab)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selection == item ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, 18)
                        .frame(height: RTIDesign.Control.segItemHeight)
                        .background(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.lg - 4)
                                .fill(selection == item ? RTIDesign.Color.cardBackground : .clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: RTIDesign.Radius.lg - 4)
                                        .stroke(selection == item ? RTIDesign.Color.borderStrong : .clear, lineWidth: 1)
                                )
                                .shadow(color: selection == item ? .black.opacity(0.06) : .clear, radius: 3, y: 1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.lg - 4)
                                .stroke(RTIDesign.Color.accent, lineWidth: 2)
                                .opacity(focusedItem == item ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focused($focusedItem, equals: item)
                .focusEffectDisabled()
            }
        }
        .padding(4)
        .frame(height: RTIDesign.Control.segTrackHeight)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.lg)
                .fill(RTIDesign.Color.trackBackground)
        )
    }
}
