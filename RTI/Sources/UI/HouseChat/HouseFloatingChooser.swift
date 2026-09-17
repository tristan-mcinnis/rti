// Copied from quick-launch@b9ee129 Sources/Views/QuickAIFloatingChooser.swift and
// Sources/Views/OverlayView.swift (AddContextPane)
import RTICore
import SwiftUI

// The choosers that float above the composer (design-system
// docs/chat-surfaces.md section 3 "Floating layers"): the `@` vault-file
// chooser, the `/` command chooser, and Add Context. Each sits at the full
// inner width on panel glass with the two panel shadows, `Spacing.xs` in from
// the sides and one composer row up. All in-window SwiftUI: never a popover or
// a child window, so they inherit the overlay's `sharingType = .none`.
//
// Keys stay in the composer field: it routes `↑` `↓` `↩` Tab and `esc`
// (`ComposerKeyRouter`), so the panes only draw and take clicks.

/// The floating layer's ground and place.
struct HouseFloatingChooser<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            // The composer's full inner width, at any size.
            .frame(maxWidth: .infinity)
            .panelGlass(radius: House.Radius.lg)
            .panelShadows()
            .padding(.horizontal, House.Spacing.xs)
    }
}

/// The chooser's title in `section` and its key hints on the right.
struct ChooserHeader: View {
    let title: String
    var hints: [(label: String, keys: [String])] = []

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            Text(title)
                .font(House.TypeToken.section)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
            Spacer(minLength: House.Spacing.xs)
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                KeyHint(label: hint.label, keys: hint.keys)
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.top, House.Spacing.xs)
    }
}

/// One chooser row: the glyph in a 26 pt tile, the title in `label`, the
/// detail in `meta` tertiary, and an optional trailing view.
struct ChooserRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String = ""
    var isSelected = false
    var height: CGFloat = House.Control.row
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: House.Spacing.sm) {
                SlateIconTile(systemName: symbol, glyphSize: House.TypeToken.Size.caption)
                HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                    Text(title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: House.Spacing.xs)
                trailing
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: height)
            .background { RowHighlight(isSelected: isSelected, isHovering: isHovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($isHovering)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension ChooserRow where Trailing == EmptyView {
    init(
        symbol: String,
        title: String,
        detail: String = "",
        isSelected: Bool = false,
        height: CGFloat = House.Control.row,
        action: @escaping () -> Void
    ) {
        self.init(symbol: symbol, title: title, detail: detail, isSelected: isSelected, height: height, action: action) {
            EmptyView()
        }
    }
}

/// A list of rows that scrolls its highlighted row into view and hugs its
/// content up to `maxRows` rows.
struct ChooserList<Item, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int
    var rowHeight: CGFloat = House.Control.row
    var maxRows = 6
    @ViewBuilder let row: (Int, Item) -> Row

    /// Rows `Spacing.xxs / 2` apart, as Quick Launch's palette spaces them.
    static var rowSpacing: CGFloat { House.Spacing.xxs / 2 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: items.count > maxRows) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        row(index, item).id(index)
                    }
                }
            }
            .frame(height: height)
            .onChange(of: selectedIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.bottom, House.Spacing.xs)
    }

    private var height: CGFloat {
        let count = CGFloat(max(1, min(items.count, maxRows)))
        return count * rowHeight + (count - 1) * Self.rowSpacing
    }
}

// MARK: - @ vault files

/// `@` typed: the vault files that match, closest first. `↩` or Tab adds the
/// highlighted file as a chip. The chooser opens on the `@` itself, so with no
/// answer yet it says it is looking instead of drawing an empty list.
struct MentionChooserPane: View {
    let candidates: [String]
    let selectedIndex: Int
    var isSearching = false
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChooserHeader(title: "Vault files", hints: [
                ("Move", ["↑", "↓"]), ("Add", ["↩"]), ("Close", ["esc"]),
            ])
            if candidates.isEmpty {
                ChooserList(items: [0], selectedIndex: -1, rowHeight: House.Control.railRow) { _, _ in
                    ChooserRow(
                        symbol: "magnifyingglass",
                        title: isSearching ? "Searching the vault…" : "No vault file matches",
                        detail: isSearching ? "Files and folders as you type" : "Keep typing to narrow it",
                        height: House.Control.railRow
                    ) {}
                }
            } else {
                ChooserList(items: candidates, selectedIndex: selectedIndex, rowHeight: House.Control.railRow) { index, path in
                    ChooserRow(
                        symbol: "doc.text",
                        title: Self.fileName(path),
                        detail: Self.folder(path),
                        isSelected: index == selectedIndex,
                        height: House.Control.railRow
                    ) { onPick(path) }
                    .help(path)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vault files")
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func folder(_ path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }
}

// MARK: - / commands

/// `/` typed: the commands that match. `↩` or Tab runs the highlighted one.
struct SlashChooserPane: View {
    let commands: [ComposerSlashCommand]
    let selectedIndex: Int
    let onRun: (ComposerSlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChooserHeader(title: "Commands", hints: [
                ("Move", ["↑", "↓"]), ("Run", ["↩"]), ("Close", ["esc"]),
            ])
            ChooserList(items: commands, selectedIndex: selectedIndex, rowHeight: House.Control.railRow) { index, command in
                ChooserRow(
                    symbol: command.symbol,
                    title: command.label,
                    detail: "/\(command.id) · \(command.help)",
                    isSelected: index == selectedIndex,
                    height: House.Control.railRow
                ) { onRun(command) }
                .help(command.help)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }
}

// MARK: - Add Context

/// One Add Context row.
struct AddContextRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case attachFile
        case vaultFile
        case readScreen
        case readWindow
        case searchScope
        case noteMode
        /// On the scope page: the whole vault, or one project or client.
        case scope(id: String?)
    }

    let kind: Kind
    let symbol: String
    let title: String
    let detail: String
    /// Key caps on the right, when the row has a key.
    var keys: [String] = []
    /// A checkmark: the current scope.
    var isCurrent = false

    var id: String {
        switch kind {
        case .scope(let id): "scope:" + (id ?? "vault")
        default: title
        }
    }
}

/// Add Context: attach a file, a vault file, one read of the screen, the
/// vault search scope, and note mode. Opened by the plus circle. The scope
/// row opens a second page of projects and clients; `esc` goes back.
struct AddContextPane: View {
    let rows: [AddContextRow]
    let selectedIndex: Int
    /// "Search Scope" on the scope page.
    var title = "Add Context"
    var isSubpage = false
    /// What the next answer can use, in one quiet line at the foot.
    var footnote: String? = nil
    let onActivate: (AddContextRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChooserHeader(title: title, hints: [
                ("Move", ["↑", "↓"]), ("Add", ["↩"]), (isSubpage ? "Back" : "Close", ["esc"]),
            ])
            ChooserList(items: rows, selectedIndex: selectedIndex) { index, row in
                ChooserRow(
                    symbol: row.symbol,
                    title: row.title,
                    detail: row.detail,
                    isSelected: index == selectedIndex
                ) {
                    onActivate(row)
                } trailing: {
                    if row.isCurrent {
                        Image(systemName: "checkmark")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .accessibilityLabel("Current")
                    } else if !row.keys.isEmpty {
                        KeyCapGroup(keys: row.keys)
                    }
                }
            }
            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.bottom, House.Spacing.sm)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
