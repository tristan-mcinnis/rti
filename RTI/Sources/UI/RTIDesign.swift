import SwiftUI

enum RTIDesign {
    // MARK: - Color
    enum Color {
        static let appBackground = SwiftUI.Color(nsColor: NSColor(red: 0.953, green: 0.953, blue: 0.961, alpha: 1))
        static let panelBackground = SwiftUI.Color(nsColor: NSColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1))
        static let trackBackground = SwiftUI.Color(nsColor: NSColor(red: 0.925, green: 0.925, blue: 0.937, alpha: 1))
        static let cardBackground = SwiftUI.Color.white
        static let inputBackground = SwiftUI.Color.white

        static let border = SwiftUI.Color(nsColor: NSColor(red: 0.851, green: 0.851, blue: 0.871, alpha: 1))
        static let borderLight = SwiftUI.Color(nsColor: NSColor(red: 0.812, green: 0.812, blue: 0.831, alpha: 1))
        static let borderStrong = SwiftUI.Color(nsColor: NSColor(red: 0.745, green: 0.745, blue: 0.769, alpha: 1))
        static let divider = border.opacity(0.6)

        static let textPrimary = SwiftUI.Color(nsColor: NSColor(red: 0.067, green: 0.067, blue: 0.078, alpha: 1))
        static let textSecondary = SwiftUI.Color(nsColor: NSColor(red: 0.345, green: 0.345, blue: 0.380, alpha: 1))
        // Bumped from (0.557,...) to (0.480,...) so it clears 4.5:1 contrast on panelBackground.
        static let textTertiary = SwiftUI.Color(nsColor: NSColor(red: 0.480, green: 0.480, blue: 0.510, alpha: 1))

        static let accent = SwiftUI.Color(red: 0.039, green: 0.518, blue: 1.0)
        static let accentText = SwiftUI.Color(red: 0.024, green: 0.463, blue: 0.847)
        static let accentBg = SwiftUI.Color(red: 0.902, green: 0.949, blue: 1.0)

        static let chipActiveBg = accentBg
        static let chipActiveText = SwiftUI.Color(red: 0.140, green: 0.514, blue: 0.820)

        // Soft tinted card for AI/assistant outputs (Summary blocks, Q&A assistant turns).
        static let aiCardBackground = SwiftUI.Color(nsColor: NSColor(red: 0.965, green: 0.973, blue: 0.984, alpha: 1))
        static let aiCardBorder = accent.opacity(0.18)

        // Toast (top-right pill).
        static let toastBackground = SwiftUI.Color.black.opacity(0.85)
        static let toastText = SwiftUI.Color.white

        // Speaker chip palette — indexed by trailing digit so Speaker 1 / 2 / 3 are stable across sessions.
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
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    // MARK: - Radius
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 28
    }

    // MARK: - Font
    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 28, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14)
        static let bodySmall = SwiftUI.Font.system(size: 13)
        static let meta = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let button = SwiftUI.Font.system(size: 13, weight: .medium)
        static let tab = SwiftUI.Font.system(size: 13, weight: .semibold)
    }

    // MARK: - Controls
    enum Control {
        static let heightSm: CGFloat = 32
        static let heightMd: CGFloat = 40
        static let heightLg: CGFloat = 48
        static let heightXl: CGFloat = 56

        static let segTrackHeight: CGFloat = 40
        static let segItemHeight: CGFloat = 32

        static let composerHeight: CGFloat = 56
        static let composerSendSize: CGFloat = 44
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

        static let storageKey = "rti.sessionDetail.density"

        static var current: Density {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? Density.comfortable.rawValue
            return Density(rawValue: raw) ?? .comfortable
        }
    }
}

// MARK: - View Extensions

extension View {
    func rtiPanelStyle(_ color: SwiftUI.Color = RTIDesign.Color.panelBackground) -> some View {
        self
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                    .stroke(RTIDesign.Color.border, lineWidth: 1)
            )
    }

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
                        .foregroundStyle(selection == item ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, 22)
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
