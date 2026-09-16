// Copied from quick-launch@b9ee129 Sources/Views/QuickAIComposer.swift
import AppKit
import RTICore
import SwiftUI

/// The composer's sizes that follow from tokens.
enum HouseComposerMetrics {
    /// The row plus its inset: `Control.pill + 2 × Spacing.xs` (52). Floating
    /// layers sit this far above the composer's bottom edge.
    static let rowHeight = House.Control.pill + House.Spacing.xs * 2

    /// The field grows to this many lines, then scrolls.
    static let maxLines = 8

    static func rowHeight(fieldHeight: CGFloat, fontSize: CGFloat) -> CGFloat {
        max(House.Control.pill, fieldHeight + 2 * textInset(fontSize: fontSize)) + 2 * House.Spacing.xs
    }

    /// Keep the palette search/footer visible as the field grows. Rows beyond
    /// this budget remain reachable in the palette's existing scroll list.
    static func paletteRows(availableHeight: CGFloat, composerHeight: CGFloat) -> Int {
        let chrome = House.Control.input + House.Spacing.lg
        let rowSpacing = House.Spacing.xxs / 2
        let rows = Int(floor((availableHeight - composerHeight - chrome + rowSpacing)
            / (House.Control.row + rowSpacing)))
        return max(1, min(5, rows))
    }

    /// One line of the field's text at `size`.
    static func lineHeight(fontSize size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Above and below the text of the field: what centres one line of text
    /// at `size` in the pill's height.
    static func textInset(fontSize size: CGFloat) -> CGFloat {
        max(0, (House.Control.pill - lineHeight(fontSize: size)) / 2)
    }
}

/// An error that belongs to no turn (a capture error, a missing key), drawn
/// above the composer row in `meta` `danger`.
struct ComposerErrorLine: Equatable {
    let message: String
    /// A fix-it button ("Open Settings"), when one exists.
    var fixTitle: String?
}

/// The composer and what sits on it (design-system docs/chat-surfaces.md
/// section 3): an error that belongs to no turn, the attachment strip, and
/// the composer row: the Add Context circle, the pill field with the primary
/// action inside it, and the `⌘K` circle. On a chat surface the row is the
/// footer; there is no footer well under it.
///
/// Values in, closures out: the owner (`AssistantInputView`) reads the app's
/// state and passes plain values, so a render proof can draw any state.
/// The field itself is the owner's (RTI keeps its `NSTextView`: it grows,
/// handles `↩` and `⇧↩`, and respects IME composition).
struct HouseComposer<Field: View>: View {
    let action: ComposerAction
    var placeholder: String
    var showsPlaceholder: Bool
    /// The field's text size (the user's text size scales it; `bodySmall`
    /// by default).
    var fontSize: CGFloat = House.TypeToken.Size.bodySmall
    var error: ComposerErrorLine? = nil
    var notice: String? = nil
    var chips: [AttachmentChipModel] = []
    var focusedChipID: String? = nil
    var isAddContextOpen = false
    var isPaletteOpen = false
    var isDropTargeted = false
    var onFix: () -> Void = {}
    var onAddContext: () -> Void = {}
    var onAction: () -> Void = {}
    var onPalette: () -> Void = {}
    var onRemoveChip: (String) -> Void = { _ in }
    var onClearChips: () -> Void = {}
    @ViewBuilder var field: Field

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                errorLine(error)
            }
            if let notice {
                Text(notice)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, House.Spacing.xs + House.Spacing.xxs)
                    .padding(.top, House.Spacing.xs)
            }
            // The strip reads as a row; the surface has no hairlines.
            if !chips.isEmpty {
                AttachmentStripView(
                    chips: chips,
                    focusedID: focusedChipID,
                    onRemove: onRemoveChip,
                    onClearAll: onClearChips
                )
            }
            composerRow
        }
        .overlay {
            if isDropTargeted {
                AttachmentDropOverlay(coversContent: true).padding(House.Spacing.xs)
            }
        }
    }

    // MARK: - Error

    private func errorLine(_ error: ComposerErrorLine) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Text(error.message)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.danger)
                .lineLimit(2)
            Spacer(minLength: House.Spacing.xs)
            if let fixTitle = error.fixTitle {
                Button(fixTitle, action: onFix)
                    .buttonStyle(InkButtonStyle())
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Row

    private var composerRow: some View {
        // The circles sit on the field's last line as it grows.
        HStack(alignment: .bottom, spacing: House.Spacing.xs) {
            Button(action: onAddContext) {
                Image(systemName: "plus")
                    .font(HouseChatType.glyphMedium)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .frame(width: House.Control.pill, height: House.Control.pill)
                    .background(Circle().fill(House.ColorToken.surfaceTint))
                    .overlay(Circle().strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .accessibilityLabel("Add Context")
            .accessibilityValue(isAddContextOpen ? "Open" : "Closed")
            .help("Attach (⇧⌘A): a file, a vault file, the screen, or the search scope")

            HStack(spacing: House.Spacing.xs) {
                field
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if showsPlaceholder {
                            // An overlay at the text origin, not the field's
                            // prompt: a styled prompt takes the field's ink.
                            Text(placeholder)
                                .font(.system(size: fontSize))
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                actionButton
            }
            .padding(.leading, House.Spacing.md)
            .padding(.trailing, House.Spacing.sm)
            // One line is the pill; a multi-line field grows from it, the
            // text inset as the pill centres one line.
            .padding(.vertical, HouseComposerMetrics.textInset(fontSize: fontSize))
            .frame(minHeight: House.Control.pill)
            // `Radius.pill` is half the row height, so this is a capsule,
            // drawn as a circular rounded rectangle: `Capsule`'s stroke
            // leaves a stray hairline outside its left cap. Outline only.
            .overlay(Self.fieldShape.strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
            .accessibilityElement(children: .contain)
            .accessibilityValue("\(action.label), \(action.keys.joined(separator: " "))")

            Button(action: onPalette) {
                // The twin of the plus circle across the field. Closed it is
                // outline only; open, the circle takes the hover fill.
                Image(systemName: "command")
                    .font(HouseChatType.glyphMedium)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .frame(width: House.Control.pill, height: House.Control.pill)
                    .background {
                        if isPaletteOpen {
                            Circle().fill(House.ColorToken.hoverFill)
                        }
                    }
                    .overlay(Circle().strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions")
            .accessibilityValue(isPaletteOpen ? "Open" : "Closed")
            .help("Actions (⌘K)")
        }
        .padding(House.Spacing.xs)
    }

    /// The primary action's title and its keys, inside the field. RTI makes
    /// it a quiet button so a pointer can send, stop, or add a note too.
    private var actionButton: some View {
        Button(action: onAction) {
            HStack(spacing: House.Spacing.xs) {
                Text(action.label)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                KeyCapGroup(keys: action.keys)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.kind == .blocked)
        .accessibilityLabel(action.label)
        .help("\(action.label) (\(action.keys.joined()))")
    }

    /// The composer field's capsule.
    private static var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
    }
}
