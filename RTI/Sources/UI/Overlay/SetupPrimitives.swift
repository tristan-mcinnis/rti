import HouseDesign
import SwiftUI

/// The Prepare page's one alignment grid and the controls it shares.
///
/// Two left edges only: section labels, cards and fields start at 0; every
/// line of text (card rows, quiet lines under a card, disclosure titles)
/// starts on the text column, past a glyph column that is `Control.tile`
/// wide and inset `Spacing.sm`.
enum SetupGrid {
    /// Where the glyph column starts.
    static let glyphInset = House.Spacing.sm
    /// Where every line of text starts.
    static let textColumn = House.Spacing.sm + House.Control.tile + House.Spacing.sm
    /// The text column measured from the glyph column (inside a padded card).
    static let textIndent = House.Control.tile + House.Spacing.sm
    /// The named coordinate space of the page's column.
    static let space = "rti.setup.page"
}

// MARK: - Inline action

/// The one inline action on the Prepare page: an outlined chip, `meta` text
/// in ink, `Control.chip` high. Change, Remove, Use, Configure, Choose…,
/// File…, Add all wear it, so every action reads as a button.
struct SetupActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SetupActionChip(configuration: configuration)
    }
}

private struct SetupActionChip: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(House.TypeToken.meta)
            .foregroundStyle(isEnabled ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(configuration.isPressed ? House.ColorToken.selectionFill : House.ColorToken.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .strokeBorder(House.ColorToken.keyCapStroke, lineWidth: House.hairline)
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SetupActionButtonStyle {
    /// The Prepare page's inline action chip.
    static var setupAction: SetupActionButtonStyle {
        SetupActionButtonStyle()
    }
}

// MARK: - Field

extension View {
    /// A one-line field on the page: plain text on `chipFill`, as tall as an
    /// action chip, so a field and its buttons share one row height. Pass the
    /// field's placeholder here, not as its prompt (see `setupPlaceholder`).
    func setupField(_ placeholder: String, isEmpty: Bool) -> some View {
        textFieldStyle(.plain)
            .font(House.TypeToken.meta)
            .setupPlaceholder(placeholder, shown: isEmpty, font: House.TypeToken.meta)
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.chip)
            .background(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous).fill(House.ColorToken.chipFill))
    }

    /// A plain field's placeholder in `textTertiary`. A SwiftUI prompt on a
    /// plain macOS field draws in near-primary ink and reads as typed text;
    /// a plain field has no text inset, so this overlay starts where typed
    /// text starts.
    func setupPlaceholder(_ text: String, shown: Bool, font: Font) -> some View {
        overlay(alignment: .leading) {
            if shown {
                Text(text)
                    .font(font)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Multi-line field

/// A multi-line field with a placeholder. The placeholder is drawn by a
/// second, read-only editor with the same font and insets, so it starts
/// exactly where typed text starts.
struct SetupTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var growsWithText = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            editor(text: $text, ink: House.ColorToken.textPrimary)
                .accessibilityLabel(accessibilityLabel)
            if text.isEmpty {
                // Not `.disabled`: a disabled editor draws in the control's
                // own ink and drops `textTertiary`. A constant binding keeps
                // it read-only; it takes no clicks and no keyboard focus.
                editor(text: .constant(placeholder), ink: House.ColorToken.textTertiary)
                    .focusable(false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(House.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous).fill(House.ColorToken.chipFill))
    }

    @ViewBuilder
    private func editor(text: Binding<String>, ink: Color) -> some View {
        let base = TextEditor(text: text)
            .font(House.TypeToken.meta)
            .foregroundStyle(ink)
            .scrollContentBackground(.hidden)
        if growsWithText {
            base.frame(minHeight: House.Control.hero).fixedSize(horizontal: false, vertical: true)
        } else {
            base.frame(height: House.Control.hero)
        }
    }
}

// MARK: - Layout probe

/// Render proofs read where the page put its text, to check the grid and
/// that nothing runs past the column. Off in the app.
struct SetupLayoutKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Report this view's frame in the page's column space under `name`
    /// when `SetupTabView.reportsLayout` is on.
    func setupLayoutMark(_ name: String) -> some View {
        modifier(SetupLayoutMark(name: name))
    }
}

private struct SetupLayoutMark: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        if SetupTabView.reportsLayout {
            content.background(GeometryReader { proxy in
                // In the column's space for the grid, and in the hosting
                // view's own space (`name@window`) for a proof's clicks.
                Color.clear.preference(key: SetupLayoutKey.self,
                                       value: [name: proxy.frame(in: .named(SetupGrid.space)),
                                               name + "@window": proxy.frame(in: .global)])
            })
        } else {
            content
        }
    }
}
