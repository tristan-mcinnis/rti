import AppKit
import HouseChatCore
import SwiftUI

/// The Sessions / Chats switch, in the window header so it is reachable with
/// the rail hidden. Chrome is ink; the segmented control takes the house
/// tint, never the system accent. A narrow header keeps the two glyphs, the
/// way the header's other chips do.
struct SessionsModeSwitch: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker(labelled: true)
            picker(labelled: false)
        }
    }

    private func picker(labelled: Bool) -> some View {
        Picker("Library", selection: $model.mode) {
            ForEach(LibraryMode.allCases) { mode in
                if labelled {
                    Text(mode.title).tag(mode)
                } else {
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Library")
        .help("Show saved session recordings or saved chats")
    }
}

// MARK: - Rail

/// The Chats list: a search field, the saved chats (Pinned, then Recent), and
/// the legacy dated logs. Selection is the open marker, apart from the
/// keyboard highlight, exactly as the session rail draws it.
struct ChatLibraryRail: View {
    @Bindable var library: ChatLibraryModel
    @FocusState private var renameFocused: Bool
    @State private var hoveredRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row.
            Color.clear.frame(height: House.Control.composer)
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    if library.isUnavailable {
                        placeholder("No chat store")
                    } else if !library.hasLoaded {
                        placeholder("Loading chats…")
                    } else {
                        if library.railRows.isEmpty, library.legacyMatches.isEmpty {
                            placeholder(library.emptyText)
                                .frame(maxWidth: .infinity, minHeight: House.Control.row)
                        }
                        ForEach(Array(library.sections.enumerated()), id: \.element.title) { _, section in
                            sectionView(section.title, rows: section.rows)
                        }
                        legacySection
                        if let linked = library.linkedLogNote {
                            railNote(linked)
                        }
                    }
                    if let error = library.errorText {
                        railNote(error)
                    }
                    if let notice = library.notice {
                        railNote(notice)
                    }
                }
                .padding(.horizontal, House.Spacing.xs)
                .padding(.bottom, House.Spacing.sm)
            }
        }
        .background(House.ColorToken.surfaceSunken)
        .clipped()
        .onChange(of: library.renameFocusRequest) { _, _ in renameFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat list")
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $library.query, prompt: Text("")) {
                Text("Search chats")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if library.query.isEmpty {
                    Text("Search chats…")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Button {
                Task { await library.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Read the chat library again")
            .accessibilityLabel("Refresh chats")
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

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textTertiary)
            .padding(.horizontal, House.Spacing.xs)
            .padding(.top, House.Spacing.xs)
    }

    private func railNote(_ text: String) -> some View {
        Text(text)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, House.Spacing.xs)
            .padding(.top, House.Spacing.sm)
    }

    private func sectionView(_ title: String, rows: [ChatLibraryRow]) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: title)
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.sm)
                .padding(.bottom, House.Spacing.xxs)
            ForEach(rows) { row in
                chatRow(row)
            }
        }
    }

    @ViewBuilder
    private var legacySection: some View {
        let logs = library.legacyMatches
        if !logs.isEmpty {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SlateSectionLabel(text: "Dated logs")
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.top, House.Spacing.sm)
                    .padding(.bottom, House.Spacing.xxs)
                ForEach(logs) { log in
                    legacyRow(log)
                }
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ row: ChatLibraryRow) -> some View {
        let isOpen = row.id == library.openID
        Group {
            if row.id == library.renamingID {
                // The rename field sits outside the row's button, so a click in
                // it edits the name and never reselects the chat.
                rowLayout(
                    title: row.title,
                    detail: library.detail(for: row),
                    isOpen: isOpen,
                    isHovering: false,
                    isPinned: row.isPinned,
                    damage: row.issue.map(ChatLibraryRules.issueText)
                ) {
                    TextField(text: $library.renameText, prompt: Text(row.title)) {
                        Text("Chat name")
                    }
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .focused($renameFocused)
                    .onSubmit { Task { await library.commitRename() } }
                }
            } else {
                Button {
                    library.select(id: row.id)
                } label: {
                    rowLayout(
                        title: row.title,
                        detail: library.detail(for: row),
                        isOpen: isOpen,
                        isHovering: hoveredRowID == row.id,
                        isPinned: row.isPinned,
                        damage: row.issue.map(ChatLibraryRules.issueText)
                    )
                }
                .buttonStyle(.plain)
                .hoverHighlight($hoveredRowID, id: row.id)
                .help(ChatLibraryRules.titleNote(for: row).map { "\(row.title) — \($0)" } ?? row.title)
            }
        }
        .contextMenu { chatMenu(row) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.turnCount) turns\(isOpen ? ", open" : "")")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityActions { chatMenu(row) }
    }

    @ViewBuilder
    private func chatMenu(_ row: ChatLibraryRow) -> some View {
        Button {
            library.resume(id: row.id)
        } label: {
            Label("Resume in RTI", systemImage: "arrow.up.forward.app")
        }
        Button {
            library.beginRename(id: row.id)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            Task { await library.togglePin(id: row.id) }
        } label: {
            Label(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin")
        }
        Button {
            Task { await library.exportJSON(id: row.id) }
        } label: {
            Label("Export Record…", systemImage: "arrow.down.doc")
        }
        Button {
            Task { await library.exportMarkdown(id: row.id) }
        } label: {
            Label("Export Markdown…", systemImage: "doc.plaintext")
        }
        Divider()
        Button(role: .destructive) {
            library.requestDeletion(id: row.id)
        } label: {
            Label("Delete Chat…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func legacyRow(_ log: ChatLibraryLegacy.Log) -> some View {
        let isOpen = log.id == library.openLogID
        Button {
            library.select(logID: log.id)
        } label: {
            rowLayout(
                title: log.title,
                detail: log.detailText,
                isOpen: isOpen,
                isHovering: hoveredRowID == log.id,
                isPinned: false,
                damage: nil
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight($hoveredRowID, id: log.id)
        .help("\(log.title) — a dated log, not a saved chat")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(log.title), dated log, \(log.turnCount) turns")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// One rail row: the open marker, a title over its detail, a pin, and the
    /// `⌘`-less trailing marks. Same shape as the session rail's row.
    private func rowLayout<Detail: View>(
        title: String,
        detail: String,
        isOpen: Bool,
        isHovering: Bool,
        isPinned: Bool,
        damage: String?,
        @ViewBuilder secondLine: () -> Detail = { EmptyView() }
    ) -> some View {
        HStack(spacing: House.Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if Detail.self == EmptyView.self {
                        Text(detail)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                    } else {
                        secondLine()
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if damage != nil {
                // The detail line already says which problem it is; the dot
                // is the house mark, and the word is in the row's label.
                SlateStatusDot(color: House.ColorToken.warning)
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(House.TypeToken.micro)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.row)
        .background { RowHighlight(isSelected: isOpen, isHovering: isHovering) }
        .overlay(alignment: .leading) {
            if isOpen {
                Capsule(style: .continuous)
                    .fill(House.ColorToken.textPrimary)
                    .frame(width: HouseChatMetrics.openChatMarkerWidth)
                    .padding(.vertical, House.Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

/// The open chat, or the open dated log, or what to do when nothing is open.
/// It also owns the one destructive confirmation and the read of the
/// selection, so a chat's turns and sources are read once per selection.
struct ChatLibraryReader: View {
    @Bindable var library: ChatLibraryModel

    var body: some View {
        Group {
            if library.isUnavailable {
                unavailable
            } else if let log = library.openLog {
                datedLogReader(log)
            } else if library.openID != nil {
                chatReader
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)
        .task(id: library.selectionKey) { await library.loadDetail() }
        .task(id: library.deletionRequest) { await library.deleteConfirmed() }
        .alert("Delete this chat?", isPresented: $library.isDeleteConfirmationPresented) {
            Button("Delete Chat", role: .destructive) { library.confirmDeletion() }
            Button("Cancel", role: .cancel) { library.cancelDeletion() }
        } message: {
            Text("“\(library.deletionTitle)” and the copies RTI saved for it will be deleted. Linked meetings, recordings, and your own files are kept.")
        }
    }

    // MARK: Chat

    private var chatReader: some View {
        VStack(spacing: 0) {
            if let notice = library.detailNoticeText {
                noticeLine(notice)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: House.Spacing.xl) {
                    if library.isLoadingDetail, library.detail == nil {
                        Text("Reading this chat…")
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textTertiary)
                    } else if let detail = library.detail {
                        if detail.turns.isEmpty, detail.record != nil {
                            Text("This chat has no turns yet.")
                                .font(House.TypeToken.bodySmall)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                        ForEach(detail.turns) { turn in
                            turnView(turn, detail: detail)
                        }
                        if !detail.sources.isEmpty {
                            sourcesCard(detail)
                        }
                    }
                }
                .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
                .padding(.horizontal, House.Spacing.lg)
                .padding(.vertical, House.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            if let row = library.openRow {
                footer(row)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: TurnRecord, detail: ChatLibraryDetail) -> some View {
        switch turn.role {
        case .user:
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                HStack {
                    Spacer(minLength: House.Spacing.xxl)
                    Text(turn.text)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, House.Spacing.sm)
                        .padding(.vertical, House.Spacing.xs)
                        .background(House.ColorToken.chipFill, in: RoundedRectangle(cornerRadius: House.Radius.pill, style: .continuous))
                }
                turnSources(turn, detail: detail)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                Text(turn.text)
                    .font(House.TypeToken.body)
                    .lineSpacing(HouseChatType.proseLineSpacing)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = turn.error, !error.isEmpty {
                    Text("This answer did not finish: \(error)")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                turnSources(turn, detail: detail)
            }
        case .system, .tool, .unknown:
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(turn.text)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                turnSources(turn, detail: detail)
            }
        }
    }

    @ViewBuilder
    private func turnSources(_ turn: TurnRecord, detail: ChatLibraryDetail) -> some View {
        if !turn.attachments.isEmpty {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                ForEach(turn.attachments) { attachment in
                    HStack(spacing: House.Spacing.xs) {
                        Image(systemName: "paperclip")
                            .font(House.TypeToken.micro)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .accessibilityHidden(true)
                        Text(attachment.name)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .lineLimit(1)
                        if let source = detail.source(for: attachment.id), source.state != .verified {
                            // A source whose copies are not all there says so here;
                            // the Saved sources card below has the detail.
                            Text("· \(source.stateText)")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sources: \(turn.attachments.map(\.name).joined(separator: ", "))")
        }
    }

    /// The saved source list, with the state of every copy the store owns.
    private func sourcesCard(_ detail: ChatLibraryDetail) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            SlateSectionLabel(text: "Saved sources")
            ForEach(detail.sources) { source in
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    HStack(spacing: House.Spacing.xs) {
                        statusDot(source.state)
                        Text(source.name)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: House.Spacing.xs)
                        Text(source.stateText)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                    }
                    Text(source.factsText)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                    Text(source.detailText)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hash = source.contentHash {
                        Text("sha256 \(hash)")
                            .font(House.TypeToken.code)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help("sha256 \(hash)")
                    }
                    if let path = source.sourcePath {
                        Text("Original: \(path)")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("The file on this Mac the source came from. The library keeps a reference and never reads it.")
                    }
                }
                .padding(House.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedCard(radius: House.Radius.md)
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ state: ChatLibrarySource.State) -> some View {
        switch state {
        case .verified:
            SlateStatusDot(color: House.ColorToken.success)
        case .missing, .mismatched, .unverifiable:
            SlateStatusDot(color: House.ColorToken.danger)
        case .noArchive:
            SlateStatusDot(color: House.ColorToken.warning)
        }
    }

    // MARK: Dated log

    private func datedLogReader(_ log: ChatLibraryLegacy.Log) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: House.Spacing.lg) {
                    Text(log.orientationText)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let projected = log.projectionNote {
                        Text(projected)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .unreadable(let reason) = log.state {
                        Text(reason)
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textSecondary)
                    } else if log.turns.isEmpty {
                        Text("This day's log has no readable turns.")
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textTertiary)
                    }
                    ForEach(log.turns) { turn in
                        VStack(alignment: .leading, spacing: House.Spacing.xs) {
                            HStack(spacing: House.Spacing.xs) {
                                Text(turn.timeText)
                                    .font(House.TypeToken.meta)
                                    .foregroundStyle(House.ColorToken.textTertiary)
                                    .monospacedDigit()
                                if !turn.detailText.isEmpty {
                                    Text(turn.detailText)
                                        .font(House.TypeToken.meta)
                                        .foregroundStyle(House.ColorToken.textTertiary)
                                }
                                Spacer(minLength: House.Spacing.sm)
                                // One stored turn is the scope, and the button
                                // says so: nothing is joined or guessed.
                                Button("Use this entry in new chat") {
                                    library.useDatedEntryInNewChat(line: turn.id)
                                }
                                .buttonStyle(.plain)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textPrimary)
                                .padding(.horizontal, House.Spacing.xs)
                                .frame(height: House.Control.chip)
                                .background(House.ColorToken.chipFill, in: Capsule())
                                .help("Reuse only this entry in a new chat. Nothing is sent until you send it.")
                                .accessibilityLabel("Use the \(turn.timeText) entry in a new chat")
                            }
                            if !turn.question.isEmpty {
                                HStack {
                                    Spacer(minLength: House.Spacing.xxl)
                                    Text(turn.question)
                                        .font(House.TypeToken.bodySmall)
                                        .foregroundStyle(House.ColorToken.textSecondary)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, House.Spacing.sm)
                                        .padding(.vertical, House.Spacing.xs)
                                        .background(House.ColorToken.chipFill, in: RoundedRectangle(cornerRadius: House.Radius.pill, style: .continuous))
                                }
                            }
                            if !turn.answer.isEmpty {
                                Text(turn.answer)
                                    .font(House.TypeToken.body)
                                    .lineSpacing(HouseChatType.proseLineSpacing)
                                    .foregroundStyle(House.ColorToken.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(turn.timeText), dated turn")
                    }
                }
                .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
                .padding(.horizontal, House.Spacing.lg)
                .padding(.vertical, House.Spacing.lg)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: House.Spacing.sm) {
                Text(library.compactStorageLine ?? "")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(library.storageLine ?? "")
                Spacer(minLength: House.Spacing.sm)
                Button("Use dated log in new chat") { library.openDatedLogAsNewChat() }
                    .buttonStyle(InkButtonStyle())
                    .help("Reuse this day's dated entries in a new chat. Nothing is sent until you send it.")
            }
            // The footer spans the reading column the same way the pane's
            // content does: the column caps the content, then the inset.
            .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
            .padding(.horizontal, House.Spacing.lg)
            .frame(maxWidth: .infinity)
            .frame(height: House.Control.footer)
            .background(House.ColorToken.well)
            .overlay(alignment: .top) {
                Rectangle().fill(House.ColorToken.divider).frame(height: House.hairline)
            }
        }
    }

    // MARK: Chrome

    private func footer(_ row: ChatLibraryRow) -> some View {
        // A chat whose file could not be read has nothing to resume, rename,
        // pin, or export. Deleting it stays available: that is the one useful
        // action on a damaged record.
        let readable = library.detail?.record != nil
        return HStack(spacing: House.Spacing.sm) {
            // The room beside four buttons and the primary action runs out at
            // the window's minimum width, so the line drops whole facts
            // rather than clipping a number.
            ViewThatFits(in: .horizontal) {
                storageFooterLine(library.compactStorageLine)
                storageFooterLine(library.countsStorageLine)
                storageFooterLine(library.chatsStorageLine)
            }
            Spacer(minLength: House.Spacing.sm)
            Button {
                Task { await library.togglePin(id: row.id) }
            } label: {
                Image(systemName: row.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(SessionCircleButtonStyle())
            .disabled(!readable)
            .help(row.isPinned ? "Unpin this chat" : "Pin this chat")
            .accessibilityLabel(row.isPinned ? "Unpin chat" : "Pin chat")
            Button {
                library.beginRename(id: row.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(SessionCircleButtonStyle())
            .disabled(!readable)
            .help("Rename this chat")
            .accessibilityLabel("Rename chat")
            Menu {
                Button("Export Record (JSON)") { Task { await library.exportJSON(id: row.id) } }
                Button("Export Markdown") { Task { await library.exportMarkdown(id: row.id) } }
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: House.Control.pill, height: House.Control.pill)
            .disabled(!readable)
            .help(readable ? "Export this chat" : "This chat's record could not be read, so there is nothing to export")
            .accessibilityLabel("Export chat")
            Button {
                library.requestDeletion(id: row.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(SessionCircleButtonStyle())
            .help("Delete this chat, keeping linked meetings and your own files")
            .accessibilityLabel("Delete chat")
            Button("Resume in RTI") { library.resume(id: row.id) }
                .buttonStyle(InkButtonStyle())
                .disabled(!readable)
                .help("Continue this chat in RTI's own chat surface")
        }
        // The footer spans the reading column the same way the pane's content
        // does: the column caps the content, then the inset.
        .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
        .padding(.horizontal, House.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: House.Control.footer)
        .background(House.ColorToken.well)
        .overlay(alignment: .top) {
            Rectangle().fill(House.ColorToken.divider).frame(height: House.hairline)
        }
    }

    private func storageFooterLine(_ text: String?) -> some View {
        Text(text ?? "")
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .lineLimit(1)
            .help(library.storageLine ?? "")
    }

    private func noticeLine(_ text: String) -> some View {        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.top, House.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: House.Spacing.xs) {
            Text("No chat open")
            Text("Saved chats and dated logs are listed on the left")
            Text("⌘⇧R starts a recording; chats save as you use them")
        }
        .font(House.TypeToken.bodySmall)
        .foregroundStyle(House.ColorToken.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: House.Spacing.xs) {
            Text("Chat library unavailable")
            Text("RTI could not resolve its vault or Application Support folder,")
            Text("so saved chats cannot be listed or read.")
        }
        .font(House.TypeToken.bodySmall)
        .foregroundStyle(House.ColorToken.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
