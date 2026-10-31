import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

extension AssistantInputView {
    // MARK: Add Context

    /// The root page's actions. `@` and `+` offer the same ones: they are the
    /// ways into the context space that are not a name.
    private var contextActionRows: [AddContextRow] {
        let scope = MeetingContextStore.shared.workstreamName ?? "Whole vault"
        return [
            AddContextRow(kind: .attachFile, symbol: "paperclip", title: "Attach File…",
                          detail: "PDF, Markdown, text, or an image, for the next question"),
            AddContextRow(kind: .vaultFile, symbol: "at", title: "Vault File",
                          detail: "Type @ and the vault list filters as you type"),
            AddContextRow(kind: .readScreen, symbol: "camera.viewfinder", title: "Screenshot Screen",
                          detail: "Whole screen; sent to the model and kept with the session", keys: ["⌘", "⇧", "H"]),
            AddContextRow(kind: .readWindow, symbol: "macwindow", title: "Screenshot Window",
                          detail: "Frontmost window; sent to the model and kept with the session", keys: ["⌘", "⇧", "J"]),
            // Above Search Scope: the pane shows five action rows at the
            // overlay's default height, so how far the search reaches has to
            // sit above the fold to be readable before Send (2026-09-23).
            AddContextRow(
                kind: .searchMode,
                symbol: "globe",
                title: "Broader Search",
                detail: isBroaderSearch
                    ? "On: the vault and the web may answer"
                    : "Off: only what you attach answers",
                isCurrent: isBroaderSearch
            ),
            AddContextRow(kind: .searchScope, symbol: "scope", title: "Search Scope", detail: scope),
            AddContextRow(
                kind: .noteMode,
                symbol: "note.text",
                title: inputState.isNoteMode ? "Back to Chat" : "Note Mode",
                detail: session.isRunning ? "↩ adds a note to the transcript" : "↩ adds a prep note",
                keys: ["⌘", "⌥", "N"]
            ),
        ]
    }

    /// RTI's own projects and clients, the rows that make this a context
    /// chooser rather than a file list.
    private var scopeItemRows: [ComposerContextRow] {
        let current = MeetingContextStore.shared.workstreamName
        return scopeItems.map { scope in
            ComposerContextRow(row: AddContextRow(
                kind: .scope(id: scope.item.id),
                symbol: scope.isClient ? "person.2" : "folder",
                title: scope.item.name,
                detail: scope.isClient ? "Client" : "Project",
                isCurrent: current == scope.item.name
            ))
        }
    }

    /// The scope page: the whole vault, then the projects and clients.
    private var scopePageRows: [ComposerContextRow] {
        let current = MeetingContextStore.shared.workstreamName
        let whole = AddContextRow(kind: .scope(id: nil), symbol: "archivebox", title: "Whole vault",
                                  detail: "Search every note", isCurrent: current == nil)
        return [ComposerContextRow(row: whole)] + scopeItemRows
    }

    /// The meetings and sessions already on disk: RTI's second addition to the
    /// context space, so `@` can reach a meeting and not only a file.
    private var meetingRows: [ComposerContextRow] {
        contextMeetings.map { meeting in
            ComposerContextRow(
                row: AddContextRow(
                    kind: .vaultFile,
                    symbol: meeting.kind == "session" ? "waveform" : "calendar",
                    title: meeting.title,
                    detail: "\(meeting.displayDate) · \(meeting.kind)"
                ),
                path: meeting.relativePath,
                keywords: [meeting.relativePath]
            )
        }
    }

    /// The vault files the mention index matched, as rows that carry their
    /// path so a pick can become a chip.
    private static func vaultFileRows(_ paths: [String]) -> [ComposerContextRow] {
        paths.map { path in
            ComposerContextRow(
                row: AddContextRow(
                    kind: .vaultFile,
                    symbol: "doc.text",
                    title: MentionChooserPane.fileName(path),
                    detail: MentionChooserPane.folder(path)
                ),
                path: path,
                // The title is only the file's name; the path is what the
                // search matched, so it has to be searchable too.
                keywords: [path]
            )
        }
    }

    /// The one search over the shared context space, for `@` and for `+`.
    /// `includeAtRest` adds RTI's meetings, projects and clients even with an
    /// empty query: the `@` chooser opens on them, while the `+` pane keeps its
    /// short action list and reaches them by typing or through its scope page.
    ///
    /// `vaultCandidates` is the vault's own matches, and only the `@` chooser
    /// passes any: the `+` pane filters locally, so typing there never reads
    /// the vault.
    ///
    /// The vault's own matches come first, as they always have in the `@`
    /// chooser, then RTI's rows, then the actions. Typing re-ranks all of it
    /// together, so this order is only what the chooser opens on.
    private func contextRows(query: String, vaultCandidates: [String], includeAtRest: Bool) -> [ComposerContextRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = Self.vaultFileRows(vaultCandidates)
        if includeAtRest || !needle.isEmpty {
            rows += meetingRows
            rows += scopeItemRows
        }
        rows += contextActionRows.map { ComposerContextRow(row: $0) }
        return Self.rankContext(rows, query: needle)
    }

    /// The Add Context pane's rows: the root page, or the scope page. Typing in
    /// the pane narrows the rows it already holds, locally, and never reads the
    /// vault; the composer draft is never touched. The highlight always indexes
    /// this list, so the keys and the drawn rows agree.
    var visibleAddContextRows: [ComposerContextRow] {
        switch addContextPage {
        case .root:
            // No vault candidates: typing here narrows the rows on screen
            // (meetings, projects, clients, the actions) and nothing else. A
            // vault-wide search belongs to `@`, which the pane's "Vault File"
            // row hands off to.
            return contextRows(query: addContextQuery, vaultCandidates: [], includeAtRest: false)
        case .scope:
            return Self.rankContext(scopePageRows, query: addContextQuery)
        }
    }

    /// The `@` chooser's rows: the same space, searched with the words typed
    /// after the `@`.
    var visibleMentionRows: [ComposerContextRow] {
        if let seededMentionRows { return seededMentionRows.map { ComposerContextRow(row: $0) } }
        return contextRows(
            query: currentMentionQuery ?? "",
            vaultCandidates: visibleMentionCandidates,
            includeAtRest: true
        )
    }

    /// Ranked the way every house chooser ranks: title first, then the row's
    /// own detail and any extra words as keywords, with the same fuzzy scorer
    /// the `⌘K` palette uses. A row that does not match is dropped.
    private static func rankContext(_ rows: [ComposerContextRow], query: String) -> [ComposerContextRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.enumerated()
            .compactMap { index, row -> (ComposerContextRow, Int, Int)? in
                guard let score = CommandRegistry.matchScore(
                    query: needle,
                    title: row.row.title,
                    keywords: [row.row.detail] + row.keywords
                ) else { return nil }
                return (row, score, index)
            }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .map(\.0)
    }

    /// "Next answer uses: Live transcript, Northwind app, Glossary".
    ///
    /// Built from the controller's own state, including the ambient screen
    /// trail and this chat's retained sources, so the footnote names what the
    /// turn actually sends. The screen label is no longer filtered out here.
    private var contextPreviewLabels: [String] {
        llm.contextPreviewLabels(question: input, freshSourceIDs: freshSourceIDs)
    }

    var contextFootnote: String? {
        let labels = contextPreviewLabels
        guard !labels.isEmpty else { return nil }
        return "Next answer uses: " + labels.joined(separator: ", ")
    }

    /// Projects (8) then clients (6), read once when a chooser opens.
    static func loadScopeItems() -> [ScopeItem] {
        VaultWorkstreamStore.projects().prefix(8).map { ScopeItem(item: $0, isClient: false) }
            + VaultWorkstreamStore.clients().prefix(6).map { ScopeItem(item: $0, isClient: true) }
    }

    /// The recent meetings and sessions for the current scope, newest first.
    static func loadContextMeetings() -> [VaultMeetings.Meeting] {
        VaultMeetings.recent(scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath, limit: 6)
    }

    /// The pane draws plain rows, so the one it hands back is looked up by
    /// value to reach the path and the keywords the search used.
    func activate(_ row: AddContextRow) {
        guard let context = visibleAddContextRows.first(where: { $0.row == row }) else { return }
        activate(context)
    }

    func activate(_ context: ComposerContextRow) {
        // The `@` chooser is a function of what is typed after the `@`: taking
        // those words out of the draft is what closes it, whichever row was
        // chosen.
        if layer == .mention { input = Self.draftWithoutMentionQuery(input) }
        if let path = context.path {
            addMention(path)
            return
        }
        switch context.row.kind {
        case .attachFile:
            isAddContextOpen = false
            fileImporterPresented = true
        case .vaultFile:
            // The action row: the hand-off to `@`, which searches the vault.
            isAddContextOpen = false
            if !input.hasSuffix("@") {
                input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + "@"
            }
        case .readScreen:
            isAddContextOpen = false
            ScreenshotManager.shared.captureAndAttach()
        case .readWindow:
            isAddContextOpen = false
            ScreenshotManager.shared.captureFocusedWindowAndAttach()
        case .searchScope:
            scopeItems = Self.loadScopeItems()
            contextMeetings = Self.loadContextMeetings()
            addContextPage = .scope
            addContextQuery = ""
            chooserIndex = 0
            addContextFocusToken &+= 1
            isAddContextOpen = true
            return
        case .searchMode:
            isAddContextOpen = false
            llm.broaderSearchEnabled.toggle()
        case .noteMode:
            isAddContextOpen = false
            toggleNoteMode()
        case .scope(let id):
            if let id, let scope = scopeItems.first(where: { $0.item.id == id }) {
                MeetingContextStore.shared.selectWorkstream(scope.item)
            } else {
                MeetingContextStore.shared.clearWorkstream()
            }
            refreshMentionSuggestions()
            addContextPage = .root
            isAddContextOpen = false
        }
        focusField()
    }

    // MARK: ⌘K palette

    /// The composer's own rows, ahead of the registry: the mode's quick
    /// actions (the primary one carries ⌘↩), then note mode, attach, the two
    /// screen reads, and the sticky recap depth (the old ✦ menu's items).
    var paletteLeadingCommands: [RTICommand] {
        let llm = llm
        var rows: [RTICommand] = llm.availableQuickActions().map { action in
            RTICommand(
                id: "chat.\(action.id)",
                title: action.label,
                subtitle: action.id == llm.primaryActionID ? "⌘↩" : action.hotkey?.display,
                keywords: action.keywords + [action.paletteTitle.lowercased()],
                perform: { llm.perform(actionID: action.id) }
            )
        }
        rows.append(RTICommand(
            id: "composer.note",
            title: inputState.isNoteMode ? "Back to Chat" : "Note Mode",
            subtitle: "⌘⌥N",
            keywords: ["note", "annotate", "transcript", "prep"],
            perform: toggleNoteMode
        ))
        rows.append(RTICommand(
            id: "composer.attach",
            title: "Attach…",
            subtitle: "⇧⌘A",
            keywords: ["pdf", "document", "file", "attach", "markdown", "context"],
            perform: toggleAddContext
        ))
        rows.append(RTICommand(
            id: "composer.screen",
            title: "Screenshot Screen",
            subtitle: "⌘⇧H",
            keywords: ["screen", "ocr", "capture", "screenshot", "display"],
            perform: { ScreenshotManager.shared.captureAndAttach() }
        ))
        rows.append(RTICommand(
            id: "composer.window",
            title: "Screenshot Window",
            subtitle: "⌘⇧J",
            keywords: ["window", "ocr", "capture", "screenshot", "frontmost", "focused"],
            perform: { ScreenshotManager.shared.captureFocusedWindowAndAttach() }
        ))
        rows += RecapDepth.allCases.map { depth in
            RTICommand(
                id: "composer.recap.\(depth.rawValue)",
                title: "Recap Depth: \(depth.label)",
                keywords: ["recap", "length", "depth", "brief", "detailed"],
                perform: { llm.recapDepth = depth },
                menuStateProvider: { llm.recapDepth == depth }
            )
        }
        return rows
    }

    func runPaletteCommand(_ command: RTICommand) {
        closePalette()
        command.perform()
        if !command.id.hasPrefix("composer.") {
            CommandRegistry.shared.recordExecution(command.id)
        }
    }

    private func toggleNoteMode() {
        inputState.mode = inputState.isNoteMode ? .chat : .liveNote
        focusField()
    }

    // MARK: Mentions

    func refreshMentionSuggestions() {
        guard seededCandidates == nil else { return }
        mentionSuggestions.update(
            query: currentMentionQuery,
            scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath
        )
    }

    /// A file or a meeting picked in either chooser becomes a chip.
    private func addMention(_ path: String) {
        if !selectedMentionPaths.contains(path) {
            selectedMentionPaths.append(path)
        }
        mentionSuggestions.update(query: nil, scopeRelativePath: nil)
        focusField()
    }

    /// The draft with the `@…` being typed taken out of it: what closes the
    /// `@` chooser.
    private static func draftWithoutMentionQuery(_ draft: String) -> String {
        guard ComposerMention.query(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The question with its chosen vault files in front of it, in the one
    /// quoted form the assistant resolves.
    func inputWithSelectedMentions(_ text: String) -> String {
        ComposerMention.line(paths: selectedMentionPaths, text: text)
    }
}
