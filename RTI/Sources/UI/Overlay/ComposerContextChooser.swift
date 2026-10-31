import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The shared context space

/// One row of the searchable context space `@` and `+` share: the row a
/// chooser draws, plus the vault path a mention carries and any extra words
/// the search should match.
struct ComposerContextRow: Equatable {
    let row: AddContextRow
    var path: String?
    var keywords: [String] = []
}

/// The `@` chooser: the same rows the `+` pane searches — RTI's projects and
/// clients, the recent meetings, the vault files the mention index matched,
/// and the composer's own actions — filtered by the words typed after the
/// `@`. The vault search is a separate lookup from the typed words, so with
/// no answer yet the chooser says it is looking instead of drawing nothing.
struct ContextChooserPane: View {
    let rows: [ComposerContextRow]
    let selectedIndex: Int
    var isSearching = false
    let onPick: (ComposerContextRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChooserHeader(title: "Add Context", hints: [
                ("Move", ["↑", "↓"]), ("Add", ["↩"]), ("Close", ["esc"]),
            ])
            if rows.isEmpty {
                ChooserList(items: [0], selectedIndex: -1, rowHeight: House.Control.railRow) { _, _ in
                    ChooserRow(
                        symbol: "magnifyingglass",
                        title: isSearching ? "Searching the vault…" : "No match",
                        detail: isSearching
                            ? "Projects, meetings and files as you type"
                            : "Keep typing to narrow it",
                        height: House.Control.railRow
                    ) {}
                }
            } else {
                ChooserList(items: rows, selectedIndex: selectedIndex, rowHeight: House.Control.railRow) { index, row in
                    ChooserRow(
                        symbol: row.row.symbol,
                        title: row.row.title,
                        detail: row.row.detail,
                        isSelected: index == selectedIndex,
                        height: House.Control.railRow
                    ) { onPick(row) } trailing: {
                        if row.row.isCurrent {
                            Image(systemName: "checkmark")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textPrimary)
                                .accessibilityLabel("Current")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add Context")
    }
}

/// How tall the composer may grow in a short window.
///
/// The house lets the field grow to eight lines, and the floating palette is
/// drawn over the thread above the composer, so at the window's minimum height
/// eight lines would push the palette's own search row off the top of the
/// panel. In a short window the field therefore gives back as many lines as the
/// chrome above it costs, and never fewer than one. In a normal window nothing
/// changes.
///
/// Internal, not file-private, so the render proofs measure the same budget the
/// composer uses.
enum ComposerFieldBudget {
    /// The field's own line limit here: the house's eight whenever there is
    /// room, fewer when there is not. `extraChrome` is any composer row above
    /// the field beyond the source and route bar (the dated-source chip row).
    static func maxLines(availableHeight: CGFloat, fontSize: CGFloat, extraChrome: CGFloat = 0) -> Int {
        let house = HouseComposerMetrics.maxLines
        guard availableHeight > 0 else { return house }
        let line = HouseComposerMetrics.lineHeight(fontSize: fontSize)
        // What has to fit under the field's growth: the palette at its
        // smallest (its search row, one result, its footer), the field's own
        // insets, the gaps between them, and the composer chrome above it.
        let floor = House.Control.input + House.Control.row + House.Control.chip
            + 2 * HouseComposerMetrics.textInset(fontSize: fontSize)
            + 3 * House.Spacing.xs
        let room = availableHeight - extraChrome - floor
        guard room > 0, line > 0 else { return 1 }
        return max(1, min(house, Int(room / line)))
    }

    /// The field's height cap at that limit.
    static func maxHeight(availableHeight: CGFloat, fontSize: CGFloat, extraChrome: CGFloat = 0) -> CGFloat {
        HouseComposerMetrics.lineHeight(fontSize: fontSize)
            * CGFloat(maxLines(availableHeight: availableHeight, fontSize: fontSize, extraChrome: extraChrome))
    }
}
