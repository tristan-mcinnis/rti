// Rail, find bar, and header copied from quick-launch@8ee19aa Sources/Views/AIChatWindowView.swift
// (AIChatRail, OpenChatMarker, AIChatFindBar, header) and CatalogPanes.swift (ChatSnippetText),
// adapted to RTI's macOS 14 floor and to reading archived sessions.
import AppKit
import RTICore
import SwiftUI

/// The Sessions window: archived meetings in the AI Chat window shape
/// (design-system docs/chat-surfaces.md sections 1, 5, 6, 7). A header in
/// the traffic-light row, the open session's files as chips, one centred
/// reading column, and the session list as a rail hidden until ⌃⌘S or the
/// header toggle. Read-only reading; past sessions belong to the vault.
///
/// State lives in `SessionsWindowModel`, so the window's keys and the render
/// proofs drive the same object.
struct SessionsBrowserView: View {
    @Bindable var model: SessionsWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode = OverlayAppearanceDefaults.defaultAppearanceMode

    init(model: SessionsWindowModel = SessionsWindowModel()) {
        self.model = model
    }

    /// The reading column: at most the Quick AI panel width less its sides.
    static let columnWidth = House.Layout.answerMaxWidth

    var body: some View {
        HStack(spacing: 0) {
            if model.isRailVisible {
                rail
                    .frame(width: House.Layout.chatRail)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(House.ColorToken.divider)
                    .frame(width: House.hairline)
                    .accessibilityHidden(true)
            }
            readingColumn
        }
        .frame(
            minWidth: House.Layout.chatMinWidth,
            maxWidth: .infinity,
            minHeight: House.Layout.chatMinHeight,
            maxHeight: .infinity
        )
        .background(House.ColorToken.surface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: House.Motion.select), value: model.isRailVisible)
        // Chrome is ink, never the system accent.
        .tint(House.ColorToken.textPrimary)
        .toggleStyle(SlateToggleStyle())
        .preferredColorScheme(preferredColorScheme)
        .task { await model.loadIfNeeded() }
        .task(id: model.mode) { await model.loadActiveLibrary() }
        .task(id: model.playbackDirectory) { await model.playback.run(directory: model.playbackDirectory) }
        .task(id: model.deletionRequest) { await model.deleteConfirmedSession() }
        .alert("Move this session to Trash?", isPresented: $model.isDeleteConfirmationPresented) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("“\(model.deletionTitle)” and its saved audio, transcript, notes, and chat will move to Trash. Restore the folder in Finder if needed. Separately exported meeting notes are kept.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOpenSessionInBrowser)) { note in
            guard let folder = note.object as? String else { return }
            model.open(folder: folder)
        }
        .sheet(isPresented: $model.isSpeakerEditorPresented) {
            SpeakerEditorSheet(model: model)
        }
        .confirmationDialog(
            "Upgrade transcript with",
            isPresented: $model.isUpgradeChoicePresented,
            titleVisibility: .visible
        ) {
            ForEach(model.upgradeProviderChoices) { provider in
                Button(model.upgradeProviderTitle(provider)) {
                    model.startTranscriptUpgrade(provider: provider)
                }
            }
            Button("Cancel", role: .cancel) { model.cancelUpgradeChoice() }
        } message: {
            Text("Soniox transcribes the saved audio again, in English and Chinese, then the summary is rewritten. The current transcript is backed up first.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private var preferredColorScheme: ColorScheme? {
        switch RTIAppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Library on screen

    /// The rail for the library on screen: the saved sessions, or the chats.
    @ViewBuilder
    private var rail: some View {
        switch model.mode {
        case .sessions: SessionsRail(model: model)
        case .chats: ChatLibraryRail(library: model.chatLibrary)
        }
    }

    /// The reading column: the open session, or the chat library. Chats mode
    /// leaves every meeting path below untouched.
    @ViewBuilder
    private var readingColumn: some View {
        switch model.mode {
        case .sessions: conversation
        case .chats: ChatLibraryReader(library: model.chatLibrary)
        }
    }

    // MARK: - Conversation column

    private var conversation: some View {
        VStack(spacing: 0) {
            SessionsHeader(model: model)
            if model.isFindPresented {
                SessionsFindBar(model: model)
            }
            if model.openRow != nil {
                SessionFileChips(model: model)
                    .frame(maxWidth: Self.columnWidth, alignment: .leading)
                    .padding(.horizontal, House.Spacing.lg)
                    .frame(maxWidth: .infinity)
                if model.openRow?.hasRetainedAudio == true {
                    SessionPlaybackBar(playback: model.playback)
                        .frame(maxWidth: Self.columnWidth)
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.top, House.Spacing.xs)
                        .frame(maxWidth: .infinity)
                }
                if let notice = model.openNotice {
                    SessionNoticeLine(text: notice.text, isRunning: notice.isRunning)
                        .frame(maxWidth: Self.columnWidth, alignment: .leading)
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.top, House.Spacing.xs)
                        .frame(maxWidth: .infinity)
                }
                SessionReader(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The scroll view would otherwise draw up under the header.
                    .clipped()
                if model.selectedFile?.name == "chat", model.openRow?.vaultTranscriptPath != nil {
                    HStack(spacing: House.Spacing.sm) {
                        Text("Saved chat")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                        Spacer(minLength: House.Spacing.sm)
                        Button("Ask about this session", systemImage: "bubble.left.and.text.bubble.right") { model.perform(.ask) }
                            .buttonStyle(.plain)
                            .font(House.TypeToken.label)
                            .padding(.horizontal, House.Spacing.sm)
                            .frame(minHeight: House.Control.pill)
                            .background(House.ColorToken.chipFill, in: Capsule())
                            .help("Open RTI's chat composer with this session's transcript attached")
                    }
                    .frame(maxWidth: Self.columnWidth)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.vertical, House.Spacing.xs)
                    .frame(maxWidth: .infinity)
                }
            } else {
                emptyState
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.actionsPlacement == .header {
                SessionActionsCard(model: model, showsKeys: true)
                    .frame(width: House.Layout.chatRail + House.Spacing.xxxxl)
                    .padding(.top, House.Control.composer)
            }
        }
    }

    /// No session to show: three hint lines, each with its real key.
    private var emptyState: some View {
        VStack(spacing: House.Spacing.xs) {
            Text(model.hasLoaded ? "No saved sessions yet" : "Loading sessions…")
            if model.hasLoaded {
                Text("⌘⇧R starts a recording")
                Text("A session saves here when it finishes")
            }
        }
        .font(House.TypeToken.bodySmall)
        .foregroundStyle(House.ColorToken.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

/// Rail toggle, the session title over its date line, then "Ask in RTI"
/// and the `⌘K` glyph. No divider under it.
private struct SessionsHeader: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            QuickAIGlyphButton(
                symbol: "sidebar.left",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: model.isRailVisible ? "Hide Session List" : "Show Session List",
                help: "\(model.isRailVisible ? "Hide" : "Show") session list (⌃⌘S)",
                accessibilityValue: model.isRailVisible ? "Open" : "Closed"
            ) {
                model.toggleRail()
            }
            HouseTitleBlock(
                title: model.windowTitle,
                // One segment, so a narrow window cuts the line once.
                line: model.windowSubtitle.isEmpty ? [] : [.text(model.windowSubtitle)]
            )
            .layoutPriority(1)
            Spacer(minLength: House.Spacing.sm)
            SessionsModeSwitch(model: model)
            if model.mode == .sessions, let row = model.openRow, row.vaultTranscriptPath != nil {
                // The labelled chip; a narrow window keeps its glyph only.
                ViewThatFits(in: .horizontal) {
                    askChip(label: true)
                    askChip(label: false)
                }
            }
            if model.mode == .sessions, let row = model.openRow {
                Button("Copy current document", systemImage: "doc.on.doc") { model.perform(.copy) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(SessionCircleButtonStyle())
                    .disabled(model.fileText.isEmpty)
                    .help("Copy current document as Markdown (⇧⌘C)")
                Button("Share current document", systemImage: "square.and.arrow.up") { model.perform(.share) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(SessionCircleButtonStyle())
                    .disabled(!model.actions(for: row).contains(.share))
                    .help("Choose where to share the current document")
                if model.actions(for: row).contains(.trash) {
                    Button("Move session to Trash", systemImage: "trash", role: .destructive) { model.perform(.trash) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(SessionCircleButtonStyle())
                        .help("Move this RTI session to Trash…")
                }
                Button("Session actions", systemImage: "command") {
                    if model.actionsPlacement == .header { model.closeActions() }
                    else { model.showActions(placement: .header) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SessionCircleButtonStyle(isSelected: model.actionsPlacement == .header))
                .help("Session actions, including export options (⌘K)")
                .accessibilityValue(model.actionsPlacement == .header ? "Open" : "Closed")
            }
        }
        // The traffic lights share this row while the rail is in.
        .padding(.leading, model.isRailVisible || model.isWindowFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: House.Control.composer)
        .background {
            ZStack {
                House.ColorToken.surface
                // A press on the header's empty space moves the window.
                WindowDragArea()
            }
        }
        .zIndex(1)
    }

    private func askChip(label: Bool) -> some View {
        Button {
            model.perform(.ask)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(House.TypeToken.label)
                if label {
                    Text("Ask in RTI")
                        .font(House.TypeToken.label)
                        .lineLimit(1)
                    KeyCapGroup(keys: ["⌘", "J"])
                }
            }
            .foregroundStyle(House.ColorToken.textPrimary)
            .padding(.horizontal, label ? House.Spacing.sm : House.Spacing.xs)
            .frame(height: House.Control.chip)
            .background(
                Capsule().fill(House.ColorToken.chipFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Ask about this session in RTI's chat (⌘J)")
        .accessibilityLabel("Ask in RTI")
    }
}

// MARK: - File chips and notice

/// The open session's files: Summary, Notes, Transcript, Chat, and so on.
/// The selected chip carries the house selection; hover is half of it.
private struct SessionFileChips: View {
    @Bindable var model: SessionsWindowModel
    @State private var hovered: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: House.Spacing.xxs) {
            ForEach(model.files) { file in
                let isSelected = model.selectedFile == file
                Button {
                    model.select(file)
                } label: {
                    Text(file.displayName)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.chip)
                        .background {
                            RowHighlight(isSelected: isSelected, isHovering: hovered == file.url, radius: House.Radius.pill)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight($hovered, id: file.url)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
            }
        }
        .padding(.bottom, House.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session files")
    }
}

/// One tool-style line for a long job: the transcript upgrade or a summary
/// regeneration. Thinking dots while it runs.
private struct SessionNoticeLine: View {
    let text: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Group {
                if isRunning {
                    ThinkingIndicator()
                } else {
                    Image(systemName: "info.circle")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
            }
            .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Find bar

/// `⌘F`: find in the open file. `↩` or `⌘G` next, `⇧↩` or `⇧⌘G` previous,
/// `esc` closes. Every hit on `hoverFill`, the current one on
/// `selectionFill`.
private struct SessionsFindBar: View {
    @Bindable var model: SessionsWindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.findQuery, prompt: Text("")) {
                Text("Find in session")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.findQuery.isEmpty {
                    Text("Find in session")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focused)
            .onSubmit { model.findNext() }
            Text(model.findStatus)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            KeyHint(label: "Next", keys: ["↩"])
            KeyHint(label: "Previous", keys: ["⇧", "↩"])
            QuickAIGlyphButton(
                symbol: "xmark",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Close Find",
                help: "Close find (esc)"
            ) {
                model.closeFind()
            }
        }
        .padding(.horizontal, House.Spacing.md)
        .frame(height: House.Control.pill)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.xs)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            if isFocused { model.focus = .find } else if model.focus == .find { model.focus = .none }
        }
        .onChange(of: model.findStatus) { _, status in
            guard !status.isEmpty else { return }
            QuickAIAnnouncement.post(status, priority: .medium)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in session")
    }
}

// MARK: - Rail

/// The session list: search, then Live, Today, This week, Earlier, or one
/// Results list while a query is typed. `↑↓` move, `↩` opens, `⌘K` the
/// highlighted row's actions, `⌘1`…`⌘9` jump (every number shows while `⌘`
/// is held), `esc` clears the search and then hides the list.
private struct SessionsRail: View {
    @Bindable var model: SessionsWindowModel
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool
    @State private var hoveredRowID: String?

    var body: some View {
        let sections = model.railSections
        let total = sections.reduce(0) { $0 + $1.rows.count }
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row.
            Color.clear.frame(height: House.Control.composer)
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
        .onAppear { if model.focus == .railSearch { searchFocused = true } }
        .onChange(of: model.railFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: model.renameFocusRequest) { _, _ in renameFocused = true }
        .onChange(of: searchFocused) { _, focused in
            if focused { model.focus = .railSearch } else if model.focus == .railSearch { model.focus = .none }
        }
        .onChange(of: renameFocused) { _, focused in
            if focused { model.focus = .rename } else if model.focus == .rename { model.focus = .none }
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
    private func rowLayout<Lines: View>(
        isSelected: Bool,
        isOpen: Bool,
        isHovering: Bool,
        number: Int?,
        @ViewBuilder lines: () -> Lines
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
            if isOpen { OpenSessionMarker() }
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

    private var session: SessionCoordinator { SessionCoordinator.shared }

    private var isLive: Bool {
        switch session.phase {
        case .recording, .paused, .finishing: true
        case .idle, .summarizing, .done: false
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
private struct SessionActionsCard: View {
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

// MARK: - Reader

/// The open file in one centred reading column.
private struct SessionReader: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
                    .padding(.top, House.Spacing.md)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.bottom, House.Spacing.xl)
                    .frame(maxWidth: .infinity)
            }
            .onChange(of: model.currentFindHit) { _, hit in
                guard let hit else { return }
                withAnimation(.easeOut(duration: House.Motion.select)) {
                    proxy.scrollTo(hit.block, anchor: UnitPoint(x: 0.5, y: 0.33))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditingSummary {
            SummaryEditor(model: model)
        } else if model.isEditingTranscript {
            TranscriptEditor(model: model)
        } else {
            switch model.document {
            case .empty:
                Text("This file is empty.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
            case let .transcript(turns):
                SessionTranscriptReader(turns: turns, model: model)
            case let .chat(turns):
                ArchivedChatThread(turns: turns, model: model)
            case let .summary(brief, record):
                VStack(alignment: .leading, spacing: House.Spacing.xl) {
                    SessionDocumentSection(title: "Share brief") {
                        MarkdownBlocks(blocks: brief, offset: 0, model: model)
                    }
                    HouseDivider()
                    SessionDocumentSection(title: "Full record") {
                        MarkdownBlocks(blocks: record, offset: brief.count, model: model)
                    }
                }
            case let .markdown(blocks):
                MarkdownBlocks(blocks: blocks, offset: 0, model: model)
            case let .intelligence(items):
                LiveIntelligenceReader(items: items, model: model)
            case let .log(text):
                let marks = model.findHighlights(inBlock: 0)
                Text(highlighted(text, marks.all, marks.current))
                    .font(House.TypeToken.code)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(0)
            case let .frames(directory):
                SessionFramesGallery(directory: directory)
            }
        }
    }
}

/// `text` with every find hit on `hoverFill` and the current one on
/// `selectionFill`.
private func highlighted(_ text: String, _ all: [Range<String.Index>], _ current: Range<String.Index>?) -> AttributedString {
    var attributed = AttributedString(text)
    for range in all {
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
        attributed[lower..<upper].backgroundColor = range == current
            ? House.ColorToken.selectionFill
            : House.ColorToken.hoverFill
    }
    return attributed
}

/// A block with a find hit: `hoverFill` behind it, the house selection
/// behind the block that holds the current hit. MarkdownUI cannot mark a
/// word, so Markdown files mark the block (transcripts and chat questions
/// mark the word).
private struct FindBlockMark: ViewModifier {
    let hasHit: Bool
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, hasHit ? House.Spacing.xs : 0)
            .padding(.vertical, hasHit ? House.Spacing.xxs : 0)
            .background {
                if hasHit {
                    RowHighlight(isSelected: isCurrent, isHovering: !isCurrent, radius: House.Radius.sm)
                }
            }
    }
}

private struct MarkdownBlocks: View {
    let blocks: [String]
    /// Index of the first block in the document's block list.
    let offset: Int
    let model: SessionsWindowModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: House.Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let marks = model.findHighlights(inBlock: offset + index)
                RTIMarkdown(block, style: .panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(FindBlockMark(hasHit: !marks.all.isEmpty, isCurrent: marks.current != nil))
                    .id(offset + index)
            }
        }
    }
}

private struct SessionDocumentSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            SlateSectionLabel(text: title)
            content
        }
        .padding(House.Spacing.md)
        .background(House.ColorToken.surfaceTint, in: RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
    }
}

// MARK: - Transcript reader

/// Transcript rows as on the live surface: a speaker chip (its speaker
/// colour is data, and the only colour here), the time, then the text in
/// `bodySmall` at line height 1.5.
private struct SessionTranscriptReader: View {
    let turns: [SessionTranscriptTurn]
    let model: SessionsWindowModel

    static let lineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: House.TypeToken.Size.bodySmall)
        let native = font.ascender - font.descender + font.leading
        return max(0, House.TypeToken.Size.bodySmall * House.TypeToken.LineHeight.bodySmall - native)
    }()

    var body: some View {
        if turns.isEmpty {
            Text("No transcript turns found.")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
        } else {
            LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let marks = model.findHighlights(inBlock: index)
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        HStack(spacing: House.Spacing.xs) {
                            SpeakerChip(name: turn.isNote ? "Note" : turn.speaker, color: speakerColor(turn))
                            Text(turn.timestamp)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .monospacedDigit()
                        }
                        Text(highlighted(turn.text, marks.all, marks.current))
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(turn.isNote ? House.ColorToken.textSecondary : House.ColorToken.textPrimary)
                            .italic(turn.isNote)
                            .lineSpacing(Self.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(index)
                }
            }
        }
    }

    /// Speaker colours are data (DESIGN.md: RTI's one categorical palette).
    /// A note has no speaker, so its dot is plain ink.
    private func speakerColor(_ turn: SessionTranscriptTurn) -> Color {
        let palette = RTIDesign.Color.speakerPalette
        guard !turn.isNote else { return House.ColorToken.textTertiary }
        let digits = turn.speaker.reversed().prefix { $0.isNumber }.reversed()
        guard let number = Int(String(digits)), !palette.isEmpty else { return House.ColorToken.textTertiary }
        return palette[(max(number, 1) - 1) % palette.count]
    }
}

private struct SpeakerChip: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            SlateStatusDot(color: color)
            Text(name)
                .font(House.TypeToken.meta.weight(.medium))
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(minHeight: HouseChatMetrics.collapseControlHeight)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.chipFill)
        )
    }
}

// MARK: - Archived chat (thread grammar, read only)

/// A past Assist chat as it looked live: the question as a pill on the
/// right (a canned action shows its name and glyph, never its prompt), the
/// context it used as tool lines, then the answer as prose with no card.
private struct ArchivedChatThread: View {
    let turns: [ArchivedChatTurn]
    let model: SessionsWindowModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                Group {
                    if turn.role == .user {
                        question(turn, index: index)
                    } else {
                        answer(turn, index: index, askedBy: index > 0 ? turns[index - 1] : nil)
                    }
                }
                .id(index)
            }
        }
    }

    private func question(_ turn: ArchivedChatTurn, index: Int) -> some View {
        let marks = model.findHighlights(inBlock: index)
        return VStack(alignment: .trailing, spacing: House.Spacing.xs) {
            if !turn.referencedPaths.isEmpty {
                HStack(spacing: House.Spacing.xs) {
                    ForEach(turn.referencedPaths, id: \.self) { path in
                        HouseChip(text: (path as NSString).lastPathComponent, icon: "doc.text")
                            .help(path)
                    }
                }
            }
            HStack(spacing: House.Spacing.xs) {
                if turn.action != nil, !turn.text.hasPrefix("/") {
                    Image(systemName: "sparkles")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(highlighted(turn.pillText, marks.all, marks.current))
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                    .fill(House.ColorToken.chipFill)
            )
            .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(turn.pillText)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func answer(_ turn: ArchivedChatTurn, index: Int, askedBy question: ArchivedChatTurn?) -> some View {
        let marks = model.findHighlights(inBlock: index)
        return VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let question, question.role == .user {
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    if question.usedTranscript { toolLine("waveform", "Used the transcript") }
                    if question.usedScreen { toolLine("camera.viewfinder", "Read the screen") }
                }
            }
            RTIMarkdown(turn.text, style: .panel)
                .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
                .modifier(FindBlockMark(hasHit: !marks.all.isEmpty, isCurrent: marks.current != nil))
        }
    }

    private func toolLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: symbol)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live intelligence reader

/// The session's findings, monochrome: the tag as a chip with its glyph,
/// the headline, why it matters, and the quote on a quiet card.
private struct LiveIntelligenceReader: View {
    let items: [ArchivedFinding]
    let model: SessionsWindowModel

    var body: some View {
        if items.isEmpty {
            Text("No intelligence items found.")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
        } else {
            LazyVStack(alignment: .leading, spacing: House.Spacing.lg) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let marks = model.findHighlights(inBlock: index)
                    VStack(alignment: .leading, spacing: House.Spacing.xs) {
                        HStack(spacing: House.Spacing.xs) {
                            HouseChip(text: item.tag, icon: icon(for: item.tag))
                            Text(item.timestamp)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .monospacedDigit()
                        }
                        Text(item.headline)
                            .font(House.TypeToken.heading)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.matters.isEmpty {
                            Text(item.matters)
                                .font(House.TypeToken.bodySmall)
                                .foregroundStyle(House.ColorToken.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let quote = item.quote {
                            Text(([item.speaker, quote].compactMap { $0 }).joined(separator: ": "))
                                .font(House.TypeToken.meta)
                                .italic()
                                .foregroundStyle(House.ColorToken.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(House.Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .raisedCard(radius: House.Radius.row)
                        }
                    }
                    .modifier(FindBlockMark(hasHit: !marks.all.isEmpty, isCurrent: marks.current != nil))
                    .id(index)
                }
            }
        }
    }

    private func icon(for tag: String) -> String {
        switch tag.lowercased() {
        case "decision": "checkmark.circle"
        case "action": "checklist"
        case "open question": "questionmark.circle"
        case "risk": "exclamationmark.triangle"
        case "follow-up": "arrowshape.turn.up.right"
        default: "lightbulb"
        }
    }
}

// MARK: - Editors

private struct SummaryEditor: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack {
                Text("Edit summary")
                    .font(House.TypeToken.heading)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Spacer()
                Button("Cancel") { model.isEditingSummary = false }
                    .buttonStyle(.plain)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Button("Save") { model.saveSummary() }
                    .buttonStyle(InkButtonStyle())
            }
            TextEditor(text: $model.summaryDraft)
                .font(House.TypeToken.bodySmall)
                .scrollContentBackground(.hidden)
                .padding(House.Spacing.xs)
                .frame(minHeight: House.Layout.chatMinHeight - House.Control.composer * 2)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(House.ColorToken.surfaceTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                )
        }
    }
}

private struct TranscriptEditor: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    Text("Edit transcript")
                        .font(House.TypeToken.heading)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    Text("Correct text or give a turn to a named speaker. Notes stay apart from speech.")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                Spacer()
                Button("Cancel") { model.isEditingTranscript = false }
                    .buttonStyle(.plain)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Button("Save") { model.saveTranscript() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.transcriptTurns.isEmpty)
            }
            ForEach($model.transcriptTurns) { $turn in
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    HStack(spacing: House.Spacing.xs) {
                        Text(turn.timestamp)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .monospacedDigit()
                        if turn.isNote {
                            Label("Note", systemImage: "note.text")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textSecondary)
                        } else {
                            TextField("Speaker", text: $turn.speaker)
                                .textFieldStyle(.roundedBorder)
                                .font(House.TypeToken.meta)
                                .frame(maxWidth: House.Layout.chatRail)
                            Menu("Assign") {
                                ForEach(model.transcriptSpeakerOptions, id: \.self) { speaker in
                                    Button(speaker) { turn.speaker = speaker }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    TextEditor(text: $turn.text)
                        .font(House.TypeToken.bodySmall)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: House.Control.hero)
                        .padding(House.Spacing.xxs)
                        .overlay(
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                        )
                }
                .padding(House.Spacing.sm)
                .raisedCard(radius: House.Radius.row)
            }
        }
    }
}

/// Name the anonymous speakers of one session. Saved only for that session.
private struct SpeakerEditorSheet: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            Text("Name speakers")
                .font(House.TypeToken.title)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text("Names save for this session only. They replace the anonymous labels in its transcript and summary.")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let labels = model.speakerLabels
            if labels.isEmpty {
                Text("No anonymous speakers in this transcript.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: House.Spacing.md, verticalSpacing: House.Spacing.sm) {
                    ForEach(labels, id: \.self) { label in
                        GridRow {
                            Text(label)
                                .font(House.TypeToken.label)
                                .foregroundStyle(House.ColorToken.textPrimary)
                            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                                TextField("Name", text: Binding(
                                    get: { model.speakerName(for: label) },
                                    set: { model.setSpeakerName($0, for: label) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                suggestion(for: label)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSpeakerEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveSpeakerNames() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(House.Spacing.xl)
        .frame(width: House.Layout.chatRail * 2)
        .background(House.ColorToken.surface)
    }

    /// The vault voice matcher's suggestion (accept or maybe band) with its
    /// score. "Use" fills the field; nothing applies until Save.
    @ViewBuilder
    private func suggestion(for label: String) -> some View {
        if let entry = model.speakerSuggestions[label], let name = entry.suggestion, entry.isAccept || entry.isMaybe {
            HStack(spacing: House.Spacing.xs) {
                Text("Voice match: \(name) (\(String(format: "%.2f", entry.score ?? 0))\(entry.isMaybe ? ", weak" : ""))")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Button("Use") { model.setSpeakerName(name, for: label) }
                    .buttonStyle(.link)
                    .font(House.TypeToken.caption)
            }
        }
    }
}
