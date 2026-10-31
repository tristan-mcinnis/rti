import AppKit
import HouseDesign
import RTICore
import SwiftUI

// MARK: - Rail

/// The session list: search, then Live, Today, This week, Earlier, or one
/// Results list while a query is typed. `↑↓` move, `↩` opens, `⌘K` the
/// highlighted row's actions, `⌘1`…`⌘9` jump (every number shows while `⌘`
/// is held), `esc` clears the search and then hides the list.
struct SessionsRail: View {
    @Environment(\.isWorkspaceEmbedded) private var embedded
    @Bindable var model: SessionsWindowModel
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool
    @State private var hoveredRowID: String?

    var body: some View {
        let sections = model.railSections
        let total = sections.reduce(0) { $0 + $1.rows.count }
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row.
            Color.clear.frame(height: embedded ? House.Spacing.xs : House.Control.composer)
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        if !model.isSearching {
                            SessionsLiveSection()
                        }
                        if total == 0, !(model.isSearching && model.contentSearchState == .searching) {
                            Text(model.railEmptyText)
                                .font(House.TypeToken.bodySmall)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: House.Control.row)
                        }
                        ForEach(Array(sections.enumerated()), id: \.element.title) { sectionIndex, section in
                            let offset = sections[..<sectionIndex].reduce(0) { $0 + $1.rows.count }
                            sectionView(section.title, rows: section.rows, offset: offset, total: total)
                        }
                        if model.isSearching {
                            contentSearchLine
                        }
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.bottom, House.Spacing.sm)
                }
                .onChange(of: model.railIndex) { _, index in
                    let rows = model.railRows
                    guard rows.indices.contains(index) else { return }
                    proxy.scrollTo(rows[index].id)
                }
            }
            if model.actionsPlacement == .rail {
                // The rail is narrow: titles win, and only ↩ shows.
                SessionActionsCard(model: model, showsKeys: false)
            }
        }
        .background(House.ColorToken.surfaceSunken)
        .clipped()
        .onAppear {
            if model.focus == .railSearch {
                searchFocused = true
            }
        }
        .onChange(of: model.railFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: model.renameFocusRequest) { _, _ in renameFocused = true }
        .onChange(of: searchFocused) { _, focused in
            if focused {
                model.focus = .railSearch
            } else if model.focus == .railSearch {
                model.focus = .none
            }
        }
        .onChange(of: renameFocused) { _, focused in
            if focused {
                model.focus = .rename
            } else if model.focus == .rename {
                model.focus = .none
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session list")
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.railQuery, prompt: Text("")) {
                Text("Search sessions")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.railQuery.isEmpty {
                    Text("Search sessions…")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($searchFocused)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .padding(.horizontal, House.Spacing.sm)
        .padding(.bottom, House.Spacing.xs)
    }

    /// Under the results: content search is running, unavailable, or done.
    @ViewBuilder
    private var contentSearchLine: some View {
        switch model.contentSearchState {
        case .searching:
            HStack(spacing: House.Spacing.xs) {
                ThinkingIndicator()
                    .frame(width: House.Control.keyCap)
                Text("Searching transcripts…")
            }
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .padding(.horizontal, House.Spacing.xs)
            .padding(.top, House.Spacing.xs)
        case .unavailable:
            Text("Content search unavailable")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, House.Spacing.xs)
                .help("Titles still filter. Transcript search needs the vault search.")
        case .idle, .done:
            EmptyView()
        }
    }

    private func sectionView(_ title: String, rows: [SessionsWindowModel.Row], offset: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: title)
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.sm)
                .padding(.bottom, House.Spacing.xxs)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: offset + index, total: total)
                    .id(row.id)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SessionsWindowModel.Row, index: Int, total: Int) -> some View {
        let isSelected = index == model.railIndex
        let isOpen = row.id == model.openRowID
        let detail = model.detail(for: row)
        let snippet = model.snippet(for: row)
        let number = model.railNumber(at: index)
        let showsNumber = number != nil && (model.isCommandHeld || isSelected || isOpen)
        Group {
            if row.id == model.renamingRowID {
                // The rename field sits outside the row's button, so a click
                // in it edits the title and never opens the session.
                rowLayout(isSelected: isSelected, isOpen: isOpen, isHovering: false, number: showsNumber ? number : nil) {
                    TextField(text: $model.renameText, prompt: Text(row.title.text)) {
                        Text("Session title")
                    }
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .focused($renameFocused)
                    .onSubmit { model.commitRename() }
                    secondLine(detail: detail, snippet: snippet)
                }
            } else {
                Button {
                    model.railIndex = index
                    model.open(row.id)
                } label: {
                    rowLayout(isSelected: isSelected, isOpen: isOpen, isHovering: hoveredRowID == row.id, number: showsNumber ? number : nil) {
                        Text(row.title.text)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        secondLine(detail: detail, snippet: snippet)
                    }
                }
                .buttonStyle(.plain)
                .hoverHighlight($hoveredRowID, id: row.id)
                // A row found by its text shows the snippet; the detail moves here.
                .help(snippet == nil ? row.title.text : "\(row.title.text), \(detail)")
            }
        }
        .contextMenu {
            ForEach(model.actions(for: row)) { action in
                Button {
                    model.perform(action, rowID: row.id)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title.text), \(snippet?.plainText ?? detail)\(isOpen ? ", open" : "")")
        .accessibilityValue(isSelected ? "Selected, \(index + 1) of \(total)" : "\(index + 1) of \(total)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            ForEach(model.actions(for: row)) { action in
                Button(action.title) { model.perform(action, rowID: row.id) }
            }
        }
    }

    /// One rail row: the open marker, two lines, and the `⌘` number.
    private func rowLayout(
        isSelected: Bool,
        isOpen: Bool,
        isHovering: Bool,
        number: Int?,
        @ViewBuilder lines: () -> some View
    ) -> some View {
        HStack(spacing: House.Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                lines()
            }
            Spacer(minLength: 0)
            if let number {
                KeyCap(text: "⌘\(number)")
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.row)
        .background { RowHighlight(isSelected: isSelected, isHovering: isHovering) }
        .overlay(alignment: .leading) {
            if isOpen {
                OpenSessionMarker()
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func secondLine(detail: String, snippet: SessionSnippet?) -> some View {
        if let snippet {
            SessionSnippetText(snippet: snippet)
        } else {
            Text(detail)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The open session's mark in the rail: a short ink bar on the row's
/// leading edge. Ink, not colour, and apart from the keyboard highlight.
private struct OpenSessionMarker: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(House.ColorToken.textPrimary)
            .frame(width: HouseChatMetrics.openChatMarkerWidth, height: House.Control.keyCap)
            .accessibilityHidden(true)
    }
}

/// A row's snippet: "Transcript: …thin **zero** scope…", the matches in
/// `meta` medium `textPrimary`, the rest `textTertiary`.
private struct SessionSnippetText: View {
    let snippet: SessionSnippet

    var body: some View {
        Text(Self.attributed(snippet))
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(snippet.plainText)
    }

    static func attributed(_ snippet: SessionSnippet) -> AttributedString {
        var text = AttributedString(snippet.label.isEmpty ? "" : snippet.label + " ")
        for run in snippet.runs {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.font = House.TypeToken.meta.weight(.medium)
                piece.foregroundColor = House.ColorToken.textPrimary
            }
            text.append(piece)
        }
        return text
    }
}

/// While a recording runs: one LIVE row on top of the list. It opens the
/// overlay. The `danger` dot plus its word is the only chroma, as in the
/// record chip; the clock ticks in this leaf only.
private struct SessionsLiveSection: View {
    @State private var isHovering = false

    private var session: SessionCoordinator {
        SessionCoordinator.shared
    }

    private var isLive: Bool {
        switch session.phase {
        case .recording, .paused, .finishing: true
        case .idle, .upgrading, .done: false
        }
    }

    var body: some View {
        if isLive {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SlateSectionLabel(text: "Live")
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.top, House.Spacing.sm)
                    .padding(.bottom, House.Spacing.xxs)
                Button {
                    WindowCoordinator.shared.showOverlay()
                } label: {
                    HStack(spacing: House.Spacing.xs) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title)
                                .font(House.TypeToken.label)
                                .foregroundStyle(House.ColorToken.textPrimary)
                                .lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack(spacing: House.Spacing.xxs) {
                                    SlateStatusDot(color: House.ColorToken.danger)
                                    Text(stateText(at: context.date))
                                        .font(House.TypeToken.meta)
                                        .foregroundStyle(House.ColorToken.textTertiary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .frame(height: House.Control.row)
                    .background { RowHighlight(isSelected: false, isHovering: isHovering) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight($isHovering)
                .help("Show the live session in RTI (⌘\\)")
                .accessibilityLabel("\(title), \(stateText(at: Date()))")
                .accessibilityHint("Shows the live session")
            }
        }
    }

    private var title: String {
        let context = MeetingContextStore.shared
        return SessionTitleResolver.liveTitle(calendarTitle: context.calendarMeeting?.title, project: context.workstreamName)
    }

    private func stateText(at date: Date) -> String {
        let seconds = Int(session.elapsed(at: date))
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        switch session.phase {
        case .paused: return "Paused · \(clock)"
        case .finishing: return "Finishing"
        default: return "Recording · \(clock)"
        }
    }
}

// MARK: - Actions card

/// `⌘K`: the session's actions on a raised card, over the rail's foot or
/// under the header's `⌘K` glyph. `↑↓` move, `↩` runs, `esc` closes. The
/// same actions are on the row's context menu and its VoiceOver actions.
struct SessionActionsCard: View {
    @Bindable var model: SessionsWindowModel
    /// Draw each action's own keys (the wider header card).
    let showsKeys: Bool
    @State private var hoveredAction: SessionsWindowModel.SessionAction?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            TextField("Search actions…", text: $model.actionQuery)
                .textFieldStyle(.plain)
                .font(House.TypeToken.bodySmall)
                .padding(.horizontal, House.Spacing.xs)
                .frame(minHeight: House.Control.chip)
                .background(House.ColorToken.surfaceTint, in: Capsule())
                .focused($searchFocused)
                .onSubmit { model.performHighlightedAction() }
                .accessibilityLabel("Search session actions")
            if let row = model.actionsRow {
                Text(row.title.text)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.top, House.Spacing.xxs)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: House.Spacing.xxs) {
                        ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
                            Button {
                                model.actionIndex = index
                                model.performHighlightedAction()
                            } label: {
                                HStack(spacing: House.Spacing.xs) {
                                    Image(systemName: action.systemImage)
                                        .font(House.TypeToken.meta)
                                        .foregroundStyle(House.ColorToken.textSecondary)
                                        .frame(width: House.Control.keyCap)
                                    Text(action.title)
                                        .font(House.TypeToken.label)
                                        .foregroundStyle(House.ColorToken.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if index == model.actionIndex {
                                        KeyCapGroup(keys: ["↩"])
                                    } else if showsKeys, !action.keys.isEmpty {
                                        KeyCapGroup(keys: action.keys)
                                    }
                                }
                                .padding(.horizontal, House.Spacing.xs)
                                .frame(height: House.Control.railRow)
                                .background {
                                    RowHighlight(isSelected: index == model.actionIndex, isHovering: hoveredAction == action)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight($hoveredAction, id: action)
                            .accessibilityAddTraits(index == model.actionIndex ? .isSelected : [])
                            .id(index)
                        }
                    }
                }
                .frame(maxHeight: House.Control.railRow * 8 + House.Spacing.xxs * 7)
                .onChange(of: model.actionIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                .onAppear { proxy.scrollTo(model.actionIndex, anchor: .center) }
            }
        }
        .padding(House.Spacing.xs)
        .raisedCard(radius: House.Radius.lg, fill: House.ColorToken.surfaceRaised)
        .houseShadow(House.Shadow.card)
        .padding(House.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session actions")
        .onAppear { searchFocused = true }
    }
}
