// Copied from quick-launch@b9ee129 Sources/Views/OverlayView.swift (QuickActionPalette)
import RTICore
import SwiftUI

/// The `⌘K` action palette (design-system docs/chat-surfaces.md section 3):
/// a search field with its `⌘K` cap, rows of an icon tile, a title, a quiet
/// detail, and the command's key caps, then one line of key hints. It floats
/// bottom right over the composer, on panel glass, in the window (never a
/// popover), so it inherits the overlay's `sharingType = .none`.
///
/// It reads the same `CommandRegistry` the menu bar and the global hotkeys
/// read, so there is no second list to drift. The host may put its own rows
/// first (`leadingCommands`: the mode's quick actions, the composer's own
/// actions); a registry row with the same id is then not drawn twice. It
/// registers no hotkey of its own.
struct CommandPaletteView: View {
    @Binding var query: String
    var onRun: (RTICommand) -> Void
    /// `esc`, or `⌘K` again.
    var onClose: () -> Void = {}
    /// Rows ahead of the registry's, in order.
    var leadingCommands: [RTICommand] = []
    /// Registry rows the host's own rows stand in for (the composer's note
    /// and screen rows replace `note.toggle` and `capture.screen`).
    var hiddenRegistryIDs: Set<String> = []
    /// Rows the list shows before it scrolls.
    var maxVisibleRows = 6

    @State private var selection = 0
    @FocusState private var searchFocused: Bool
    private let registry = CommandRegistry.shared

    /// The rows for a query: the host's rows that match, then the registry's
    /// (recents first when the query is empty).
    static func entries(
        query: String,
        leading: [RTICommand],
        registry: [RTICommand],
        hiding hidden: Set<String> = []
    ) -> [RTICommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hosted = leading.filter { command in
            guard command.isAvailable() else { return false }
            guard !needle.isEmpty else { return true }
            return command.title.lowercased().contains(needle)
                || command.keywords.contains { $0.lowercased().contains(needle) }
        }
        let taken = Set(hosted.map(\.id)).union(hidden)
        return hosted + registry.filter { !taken.contains($0.id) }
    }

    private var entries: [RTICommand] {
        Self.entries(query: query, leading: leadingCommands, registry: registry.search(query), hiding: hiddenRegistryIDs)
    }

    var body: some View {
        let rows = entries
        VStack(spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.sm) {
                TextField(text: $query, prompt: Text("Search actions")) {
                    Text("Search actions")
                }
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .focused($searchFocused)
                .onSubmit { run(at: selection, in: rows) }
                .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onExitCommand { onClose() }
                .onKeyPress(characters: CharacterSet(charactersIn: "k")) { press in
                    guard press.modifiers == .command else { return .ignored }
                    onClose()
                    return .handled
                }
                .accessibilityLabel("Search actions")
                KeyCapGroup(keys: ["⌘", "K"])
            }
            .padding(.horizontal, House.Spacing.lg)
            .padding(.top, House.Spacing.sm)

            if rows.isEmpty {
                Text("No actions match")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: House.Control.row)
                    .padding(.horizontal, House.Spacing.lg)
            } else {
                ChooserList(items: rows, selectedIndex: selection, maxRows: maxVisibleRows) { index, command in
                    row(command, index: index, count: rows.count, isSelected: index == selection)
                }
            }

            HStack(spacing: House.Spacing.sm) {
                Text("↑↓ Navigate")
                Text("↩ Run")
                Spacer(minLength: House.Spacing.xs)
                Text("Esc Close")
            }
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .padding(.horizontal, House.Spacing.lg)
            .padding(.bottom, House.Spacing.sm)
            .accessibilityHidden(true)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func row(_ command: RTICommand, index: Int, count: Int, isSelected: Bool) -> some View {
        ChooserRow(
            symbol: Self.symbol(for: command),
            title: Self.displayTitle(for: command),
            detail: Self.group(for: command),
            isSelected: isSelected
        ) {
            onRun(command)
        } trailing: {
            if let isOn = command.menuStateProvider?() {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .accessibilityLabel("On")
                }
            } else if let keys = Self.keyCaps(for: command) {
                KeyCapGroup(keys: keys)
            }
        }
        .accessibilityValue(isSelected ? "Selected, \(index + 1) of \(count)" : "\(index + 1) of \(count)")
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run(at index: Int, in rows: [RTICommand]) {
        guard rows.indices.contains(index) else { return }
        onRun(rows[index])
    }

    // MARK: - Words and glyphs

    /// The title as a row reads it: no shortcut typed into the title (the
    /// caps say it), and a submenu's name ahead of a bare choice ("Set ⌘⏎
    /// to: Recap").
    static func displayTitle(for command: RTICommand) -> String {
        let title = command.title.components(separatedBy: "  ").first ?? command.title
        if let parent = command.menuParent, !title.contains(":") {
            return "\(parent): \(title)"
        }
        return title
    }

    /// The command's shortcut as caps: "⌘⇧R" → ⌘ ⇧ R.
    static func keyCaps(for command: RTICommand) -> [String]? {
        guard let subtitle = command.subtitle, !subtitle.isEmpty else { return nil }
        return subtitle.map { $0 == "⏎" ? "↩" : String($0) }
    }

    /// A quiet word for where the command belongs.
    static func group(for command: RTICommand) -> String {
        let id = command.id
        if id.hasPrefix("composer.") { return "Composer" }
        if id.hasPrefix("chat.") { return "Quick action" }
        if id.hasPrefix("primary.") { return "Assist" }
        if id.hasPrefix("session.") || id.hasPrefix("mic.") || id.hasPrefix("note.") || id.hasPrefix("capture.") {
            return "Session"
        }
        if id.hasPrefix("view.") || id == "overlay.toggle" { return "Go to" }
        if id.hasPrefix("llm.") || id.hasPrefix("stt.") || id == "smart.toggle" { return "Model" }
        if id.hasPrefix("mode.") || id == "listener.toggle" || id == "fieldwork.preset" { return "Mode" }
        if id.hasPrefix("meeting.") { return "Meeting" }
        return "RTI"
    }

    /// The row's glyph, from the command's id.
    static func symbol(for command: RTICommand) -> String {
        let id = command.id
        if id.hasPrefix("chat."), let action = AssistantAction.byID(String(id.dropFirst("chat.".count))) {
            return action.symbol
        }
        let table: [(String, String)] = [
            ("composer.attach", "paperclip"),
            ("composer.recap", "arrow.clockwise"),
            ("composer.note", "note.text"),
            ("composer.screen", "camera.viewfinder"),
            ("chat.primary", "command"),
            ("chat.recap", "arrow.clockwise"),
            ("chat.clear", "square.and.pencil"),
            ("primary.set", "command"),
            ("session.start", "record.circle"),
            ("session.pause", "pause"),
            ("mic.", "mic.slash"),
            ("note.", "note.text"),
            ("capture.", "camera.viewfinder"),
            ("overlay.toggle", "macwindow"),
            ("view.sessions", "clock.arrow.circlepath"),
            ("view.brief", "doc.text"),
            ("view.tab", "rectangle.split.3x1"),
            ("meeting.", "folder"),
            ("llm.", "cpu"),
            ("stt.", "waveform"),
            ("smart.", "sparkles"),
            ("listener.", "ear"),
            ("fieldwork.", "person.2.wave.2"),
            ("invisibility.", "eye.slash"),
            ("mode.", "slider.horizontal.3"),
            ("settings.", "gearshape"),
            ("app.about", "info.circle"),
            ("app.checkUpdates", "arrow.down.circle"),
            ("app.quit", "power"),
        ]
        return table.first { id.hasPrefix($0.0) }?.1 ?? "command"
    }
}
