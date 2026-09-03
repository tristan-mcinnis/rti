import RTICore
import SwiftUI

/// The command list, drawn as a Slate panel: the launcher's input row, section
/// label, 40 px rows with an icon tile and a shortcut, and the footer well.
///
/// It reads the same `CommandRegistry` the menubar and the global hotkeys read,
/// so there is no second list to drift. It is presentation only — it registers
/// no hotkey of its own, because RTI's shortcuts are Carbon-registered global
/// chords and adding one would change behaviour, not appearance.
struct CommandPaletteView: View {
    @Binding var query: String
    var onRun: (RTICommand) -> Void

    @State private var selection = 0
    private let registry = CommandRegistry.shared

    private var results: [RTICommand] {
        Array(registry.search(query).prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow

            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(height: House.hairline)

            VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs) {
                SlateSectionLabel(text: query.isEmpty ? "Recent" : "Results")
                    .padding(.horizontal, RTIDesign.Spacing.sm)
                    .padding(.top, RTIDesign.Spacing.sm)

                ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                    row(command, selected: index == selection)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, RTIDesign.Spacing.xs)

            SlateFooter(statusColor: RTIDesign.Color.success, status: "\(results.count) commands") {
                SlateKeyHint(label: "Run", keys: ["↩"])
                SlateKeyHint(label: "Close", keys: ["esc"])
            }
        }
        .background(SlateGlassBackground(cornerRadius: RTIDesign.Radius.lg, stroked: true))
        .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.lg, style: .continuous))
    }

    private var inputRow: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(RTIDesign.Font.input)
                .foregroundStyle(RTIDesign.Color.textTertiary)
            TextField("Search commands", text: $query)
                .textFieldStyle(.plain)
                .font(RTIDesign.Font.input)
                .foregroundStyle(RTIDesign.Color.textPrimary)
        }
        .padding(.horizontal, RTIDesign.Spacing.md)
        .frame(height: House.Control.input)
    }

    private func row(_ command: RTICommand, selected: Bool) -> some View {
        Button {
            onRun(command)
        } label: {
            HStack(spacing: RTIDesign.Spacing.sm) {
                SlateIconTile(systemName: "command", glyphSize: 12)
                Text(command.title)
                    .font(RTIDesign.Font.label)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: RTIDesign.Spacing.xs)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    HStack(spacing: RTIDesign.Spacing.xxs) {
                        ForEach(Array(subtitle.map(String.init).enumerated()), id: \.offset) { _, key in
                            SlateKeyCap(symbol: key)
                        }
                    }
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xs)
            .frame(height: RTIDesign.Control.heightMd)
            .slateRaisedTile(selected, cornerRadius: RTIDesign.Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
