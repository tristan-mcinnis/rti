import SwiftUI

enum RTIDesign {
    // MARK: - Color
    enum Color {
        static let appBackground = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.953, green: 0.953, blue: 0.961, alpha: 1))
        static let panelBackground = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.969, green: 0.969, blue: 0.973, alpha: 1))
        static let trackBackground = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.937, alpha: 1))
        static let cardBackground = SwiftUI.Color.white
        static let inputBackground = SwiftUI.Color.white

        static let border = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.851, green: 0.851, blue: 0.871, alpha: 1))
        static let borderLight = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.812, green: 0.812, blue: 0.831, alpha: 1))
        static let divider = border.opacity(0.6)

        static let textPrimary = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.067, green: 0.067, blue: 0.078, alpha: 1))
        static let textSecondary = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.400, green: 0.400, blue: 0.427, alpha: 1))
        static let textTertiary = SwiftUI.Color(nsColor: NSColor(calibratedRed: 0.557, green: 0.557, blue: 0.584, alpha: 1))

        static let accent = SwiftUI.Color(red: 0.039, green: 0.518, blue: 1.0)
        static let accentText = SwiftUI.Color(red: 0.024, green: 0.463, blue: 0.847)
        static let accentBg = SwiftUI.Color(red: 0.902, green: 0.949, blue: 1.0)

        static let chipActiveBg = accentBg
        static let chipActiveText = SwiftUI.Color(red: 0.140, green: 0.514, blue: 0.820)
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
        static let tab = SwiftUI.Font.system(size: 13, weight: .medium)
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
        static let composerSendSize: CGFloat = 42
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
}

// MARK: - Custom Segmented Picker

struct RTISegmentedPicker<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let items: [T]

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
                                        .stroke(selection == item ? RTIDesign.Color.borderLight : .clear, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
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
