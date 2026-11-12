import HouseDesign
import SwiftUI

/// The rail folded to one line for a narrow window, such as
/// "2 to ask · 1 to revisit · 14 topics". A click asks the Live page to open
/// the full rail in a sheet attached to the window (`LiveRailSheet`), never
/// a floating panel. The page owns the sheet, so it outlives the strip.
struct LiveRailStrip: View {
    let summary: String
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "sidebar.right")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                Text(summary)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: House.Spacing.xs)
                Text("Show")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background {
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(hovering ? House.ColorToken.hoverFill : House.ColorToken.surfaceSunken)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel("Live help: \(summary)")
        .accessibilityHint("Opens the live help rail")
        .help("Show live help")
    }
}

/// The full rail in a sheet, opened from the strip.
struct LiveRailSheet<Rail: View>: View {
    let done: () -> Void
    @ViewBuilder var rail: () -> Rail

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live help")
                    .font(House.TypeToken.heading)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(House.Spacing.md)
            rail()
        }
        .frame(width: LiveRailLayout.width + House.Spacing.xxxxl,
               height: House.Layout.chatMinHeight)
        .background(House.ColorToken.surface)
    }
}
