import AppKit
import Observation
import RTICore
import UniformTypeIdentifiers

/// State behind the Sessions window: the list rail (titles, search, date
/// groups, row actions), the open session and its files, find, and the
/// editors. The window, its keys, and every render proof drive this one
/// object, so a proof can put the window in any state without a click.
///
/// Read-only over the archive except for what the old browser already
/// wrote: a manual title, speaker names, summary and transcript edits, a
/// transcript upgrade, a regenerated summary, and now a generated title for
/// a session that has notes but no title. It never touches the session
/// writer or the recording path.
@MainActor
@Observable
final class SessionsWindowModel {
    // MARK: - Dependencies

    /// What the model reaches outside the archive. `live` in the app;
    /// render proofs pass their own (no network, no writes).
    struct Dependencies {
        /// Content search through the vault's index (tier 2). Nil: the rail
        /// says "Content search unavailable" and filters titles only.
        var contentSearch: (@Sendable (String) async -> [VaultSearch.Result]?)?
        /// The short generated title (rule 5). Nil: never generate.
        var generateTitle: (@MainActor (_ notesMarkdown: String) async -> String?)?
        /// Save a generated title next to the session.
        var persistGeneratedTitle: @MainActor (_ title: String, _ sessionDirectory: URL) -> Void
        var now: @Sendable () -> Date
        var trashSession: (@Sendable (URL) async throws -> Void)? = nil
        var shareText: (@MainActor (String) -> Void)? = nil

        /// The running app: the vault search CLI and the title call. Both
        /// switch off outside RTI's own bundle (a test runner), so no test
        /// can reach the network or write a title into an archive.
        static var live: Dependencies {
            var dependencies = Dependencies(
                contentSearch: nil,
                generateTitle: nil,
                persistGeneratedTitle: { title, directory in SessionTitleGenerator.persist(title, in: directory) },
                now: { Date() }
            )
            guard Bundle.main.bundleIdentifier == "com.tristan.rti.personal" else { return dependencies }
            let archiveActions = SessionArchiveActions()
            dependencies.trashSession = { directory in try await archiveActions.moveToTrash(directory) }
            dependencies.shareText = { text in
                guard let view = NSApp.keyWindow?.contentView else { return }
                NSSharingServicePicker(items: [text]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
            dependencies.contentSearch = { query in
                await VaultSearchCLI.search(query: query, limit: contentResultLimit)
            }
            dependencies.generateTitle = { notes in
                await SessionTitleGenerator.generate(notesMarkdown: notes)
            }
            return dependencies
        }

        /// Vault search results asked for per content search.
        static let contentResultLimit = 12
    }

    // MARK: - Types

    /// One archived session as the window shows it.
    struct Row: Identifiable, Equatable, Sendable {
        let session: SessionArchive.ArchivedSession
        var title: ResolvedSessionTitle
        let durationSeconds: Int?
        let project: String?
        let mode: String?
        let speakerNames: [String]
        let stamp: String?
        let hasNotes: Bool
        let transcriptStatus: String?
        /// "Summary unavailable" when the end-of-session summary never
        /// landed. The row says so rather than leaving a silent gap.
        var summaryStatus: String?
        /// Read once at load (off the main thread), so row menus stay cheap.
        var hasTranscript = false
        var hasSummary = false
        var hasRetainedAudio = false
        /// `transcript.md` relative to `databases/`, for Ask in RTI.
        var vaultTranscriptPath: String?

        var id: String { session.url.path }
        var folderName: String { session.url.lastPathComponent }
        /// A built title (date and length, or a short test), not a name.
        var isFallbackTitle: Bool { title.source == .fallback || title.source == .shortTest }

        var railItem: SessionRailItem {
            SessionRailItem(
                id: id,
                title: title.text,
                startedAt: session.date,
                durationSeconds: durationSeconds,
                project: project,
                mode: mode,
                speakerNames: speakerNames,
                stamp: stamp
            )
        }
    }

    /// One file pill under the header.
    struct SessionFile: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        /// "summary", "notes", "transcript", "chat", "frames", "log", …
        let name: String

        var displayName: String {
            switch name {
            case "summary": "Summary"
            case "live-intelligence": "Intelligence"
            case "notes": "Notes"
            case "transcript": "Transcript"
            case "chat": "Chat"
            case "discussion-guide": "Guide"
            case "screen-context": "Screen"
            case "frames": "Screenshots"
            case "log": "Log"
            default: name.capitalized
            }
        }
    }

    /// The open file, split into the blocks the reader draws, so find can
    /// mark and scroll to the block that holds a hit.
    enum ReaderDocument: Equatable {
        case empty
        case transcript([SessionTranscriptTurn])
        case chat([ArchivedChatTurn])
        /// A summary in the two-part format: the share brief, then the record.
        case summary(brief: [String], record: [String])
        case markdown([String])
        case intelligence([ArchivedFinding])
        case log(String)
        case frames(URL)

        /// The searchable text of each block, in drawing order.
        var blockTexts: [String] {
            switch self {
            case .empty, .frames: []
            case let .transcript(turns): turns.map(\.text)
            case let .chat(turns): turns.map { $0.role == .user ? $0.pillText : $0.text }
            case let .summary(brief, record): brief + record
            case let .markdown(blocks): blocks
            case let .intelligence(items): items.map(\.searchText)
            case let .log(text): [text]
            }
        }
    }

    /// One find hit: which block, and where in its text.
    struct FindHit: Equatable {
        let block: Int
        let range: Range<String.Index>
    }

    enum ContentSearchState: Equatable { case idle, searching, done, unavailable }
    enum ActionsPlacement: Equatable { case rail, header }
    enum Focus: Equatable { case none, railSearch, find, rename }

    /// A session action: in the `⌘K` card, the row's context menu, and its
    /// VoiceOver actions. Removal is confirmed and moves only RTI's own
    /// archive folder to Trash, never its separately exported meeting notes.
    enum SessionAction: String, CaseIterable, Identifiable {
        case ask, rename, nameSpeakers, editTranscript, editSummary
        case upgradeTranscript, regenerateSummary, copy, share, saveMarkdown, savePDF, revealInFinder, trash

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ask: "Ask in RTI"
            case .rename: "Rename"
            case .nameSpeakers: "Name Speakers"
            case .editTranscript: "Edit Transcript"
            case .editSummary: "Edit Summary"
            case .upgradeTranscript: "Upgrade Transcript"
            case .regenerateSummary: "Regenerate Summary"
            case .copy: "Copy as Markdown"
            case .share: "Share…"
            case .trash: "Move to Trash…"
            case .saveMarkdown: "Save as Markdown"
            case .savePDF: "Save as PDF"
            case .revealInFinder: "Reveal in Finder"
            }
        }

        var systemImage: String {
            switch self {
            case .ask: "bubble.left.and.text.bubble.right"
            case .rename: "pencil"
            case .nameSpeakers: "person.2"
            case .editTranscript: "text.bubble"
            case .editSummary: "square.and.pencil"
            case .upgradeTranscript: "waveform.badge.magnifyingglass"
            case .regenerateSummary: "arrow.clockwise"
            case .copy: "doc.on.doc"
            case .share: "square.and.arrow.up"
            case .trash: "trash"
            case .saveMarkdown: "arrow.down.doc"
            case .savePDF: "doc.richtext"
            case .revealInFinder: "folder"
            }
        }

        /// The window key that runs it from anywhere, as key caps.
        var keys: [String] {
            switch self {
            case .ask: ["⌘", "J"]
            case .rename: ["⌘", "E"]
            case .copy: ["⇧", "⌘", "C"]
            case .saveMarkdown: ["⌘", "S"]
            default: []
            }
        }
    }

    // MARK: - State

    let dependencies: Dependencies
    let playback = SessionPlaybackModel()
    var isWindowVisible = true
    var isDeleteConfirmationPresented = false
    private(set) var pendingDeletionRowID: String?
    private(set) var deletionRequest: UUID?
    private(set) var isDeleting = false
    var playbackDirectory: URL? {
        guard isWindowVisible, openRow?.hasRetainedAudio == true else { return nil }
        return openRow?.session.url
    }
    var deletionTitle: String { rows.first { $0.id == pendingDeletionRowID }?.title.text ?? "this session" }

    private(set) var rows: [Row] = []
    private(set) var titleMap: VaultMeetingTitleMap = .empty
    private(set) var hasLoaded = false
    private(set) var openRowID: String?

    /// The list rail. The choice is remembered; a deep link opens with it
    /// hidden, on that session, without changing the remembered choice.
    var isRailVisible: Bool
    var isWindowFullScreen = false
    var railQuery = "" {
        didSet {
            guard railQuery != oldValue else { return }
            railQueryChanged()
        }
    }
    /// Keyboard highlight in the rail's rows (apart from the open marker).
    var railIndex = 0
    /// ⌘ held: every row shows its ⌘1…⌘9 number.
    var isCommandHeld = false
    private(set) var contentSnippets: [String: SessionSnippet] = [:]
    private(set) var contentOnlyIDs: [String] = []
    private(set) var contentSearchState: ContentSearchState = .idle

    var actionsPlacement: ActionsPlacement?
    var actionIndex = 0
    var actionQuery = "" { didSet { if actionQuery != oldValue { actionIndex = 0 } } }
    private(set) var actionsRowID: String?

    private(set) var renamingRowID: String?
    var renameText = ""

    var isFindPresented = false {
        didSet { if isFindPresented != oldValue { recomputeFindHits() } }
    }
    var findQuery = "" {
        didSet {
            guard findQuery != oldValue else { return }
            findIndex = 0
            recomputeFindHits()
        }
    }
    var findIndex = 0
    /// Every hit in the open file, in order; kept so a draw never rescans.
    private(set) var findHits: [FindHit] = []
    private var findHitsByBlock: [Int: [Range<String.Index>]] = [:]

    var focus: Focus = .none
    /// Bumped to ask a field to take focus (the view watches them).
    private(set) var railFocusRequest = 0
    private(set) var findFocusRequest = 0
    private(set) var renameFocusRequest = 0

    // The open session.
    private(set) var files: [SessionFile] = []
    private(set) var selectedFile: SessionFile?
    private(set) var fileText = ""
    private(set) var document: ReaderDocument = .empty
    private(set) var speakerNames: [String: String] = [:]

    // Editors and long jobs.
    var isEditingSummary = false
    var summaryDraft = ""
    var isEditingTranscript = false
    var transcriptTurns: [SessionTranscriptTurn] = []
    var isSpeakerEditorPresented = false
    private(set) var speakerSuggestions: [String: SpeakerSuggestions.Entry] = [:]
    var isUpgradeChoicePresented = false
    private(set) var pendingUpgradeRowID: String?
    private(set) var upgradingRowID: String?
    private(set) var regeneratingRowID: String?
    private(set) var notice: (rowID: String, text: String)?

    @ObservationIgnored private var contentSearchTask: Task<Void, Never>?
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var titleAttempts: Set<String> = []
    @ObservationIgnored private var pendingFolder: String?
    @ObservationIgnored private var isLoading = false

    static let railVisibleKey = "rti.sessions.railVisible"
    /// How many sessions the list loads.
    static let listLimit = 200

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        let stored = UserDefaults.standard.object(forKey: Self.railVisibleKey) as? Bool
        self.isRailVisible = stored ?? true
    }

    // MARK: - Derived

    var openRow: Row? { rows.first { $0.id == openRowID } }

    var isSearching: Bool { !railQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The rail's sections in drawing order. While a query is typed: one
    /// Results list, title matches first, then rows found by content.
    var railSections: [(title: String, rows: [Row])] {
        let now = dependencies.now()
        if isSearching {
            let titleHits = rows.filter { SessionsWindowRules.matches($0.railItem, query: railQuery, now: now) }
            let titleIDs = Set(titleHits.map(\.id))
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let contentHits = contentOnlyIDs.filter { !titleIDs.contains($0) }.compactMap { byID[$0] }
            let results = titleHits + contentHits
            return results.isEmpty ? [] : [("Results", results)]
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionsWindowRules.grouped(rows.map(\.railItem), now: now).map { group in
            (group.group.rawValue, group.items.compactMap { byID[$0.id] })
        }
    }

    /// The rail's rows in order, for ⌘1…⌘9, ↑↓, and VoiceOver positions.
    var railRows: [Row] { railSections.flatMap(\.rows) }

    var railEmptyText: String {
        if rows.isEmpty { return hasLoaded ? "No sessions yet" : "Loading sessions…" }
        return "No sessions match"
    }

    /// The row's second line: its snippet while a search found it by
    /// content, else time, length, and project.
    func detail(for row: Row) -> String {
        SessionsWindowRules.detailLine(for: row.railItem, titleSource: row.title.source, now: dependencies.now())
    }

    /// Characters a rail snippet keeps before its first match.
    static let railSnippetLead = 6

    func snippet(for row: Row) -> SessionSnippet? {
        guard isSearching, !SessionsWindowRules.matches(row.railItem, query: railQuery, now: dependencies.now()) else { return nil }
        return contentSnippets[row.id]?.keepingLead(Self.railSnippetLead)
    }

    /// ⌘1…⌘9 number for a row index, or nil past nine.
    func railNumber(at index: Int) -> Int? {
        index < 9 ? index + 1 : nil
    }

    /// The header's second line for the open session: "Sep 4 · 15:00 ·
    /// 16 min · Northwind app · Transcript upgraded". Like the rail row, it
    /// never repeats what a built title already says.
    var headerLine: String {
        guard let row = openRow else {
            return hasLoaded ? "\(rows.count) saved session\(rows.count == 1 ? "" : "s")" : ""
        }
        let now = dependencies.now()
        var parts: [String] = []
        if row.title.source != .fallback, let date = row.session.date {
            parts.append(SessionsWindowRules.headerDay(date, now: now))
            parts.append(SessionsWindowRules.timeText(date))
        }
        if !row.isFallbackTitle, let seconds = row.durationSeconds {
            parts.append(SessionTitleResolver.durationText(seconds))
        }
        if let project = row.project, !project.isEmpty { parts.append(project) }
        if let status = row.transcriptStatus { parts.append(status) }
        if let status = row.summaryStatus { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Find

    private func recomputeFindHits() {
        guard isFindPresented else {
            findHits = []
            findHitsByBlock = [:]
            return
        }
        findHits = document.blockTexts.enumerated().flatMap { index, text in
            SessionsWindowRules.findRanges(of: findQuery, in: text).map { FindHit(block: index, range: $0) }
        }
        findHitsByBlock = Dictionary(grouping: findHits, by: \.block).mapValues { $0.map(\.range) }
    }

    var currentFindHit: FindHit? {
        let hits = findHits
        guard !hits.isEmpty else { return nil }
        return hits[min(max(findIndex, 0), hits.count - 1)]
    }

    var findStatus: String {
        SessionsWindowRules.findStatus(current: findIndex, total: findHits.count, query: findQuery)
    }

    /// Every hit range in one block, and the current one if it is here.
    func findHighlights(inBlock block: Int) -> (all: [Range<String.Index>], current: Range<String.Index>?) {
        guard let ranges = findHitsByBlock[block] else { return ([], nil) }
        let current = currentFindHit.flatMap { $0.block == block ? $0.range : nil }
        return (ranges, current)
    }

    func findNext() { stepFind(1) }
    func findPrevious() { stepFind(-1) }

    private func stepFind(_ delta: Int) {
        let count = findHits.count
        guard count > 0 else { return }
        findIndex = (findIndex + delta + count) % count
    }

    func showFind() {
        isFindPresented = true
        findFocusRequest += 1
    }

    func closeFind() {
        isFindPresented = false
        findQuery = ""
        if focus == .find { focus = .none }
    }

    // MARK: - Loading

    /// Load the list once (the window's first appearance), unless a load
    /// is already on its way.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Reload the list and the vault note titles off the main thread, then
    /// keep the open session (or open the newest one) and start the lazy
    /// title generation.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let limit = Self.listLimit
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadRows(limit: limit)
        }.value
        apply(rows: loaded.rows, titleMap: loaded.map)
    }

    private func apply(rows newRows: [Row], titleMap map: VaultMeetingTitleMap) {
        rows = newRows
        titleMap = map
        hasLoaded = true
        if let folder = pendingFolder, let row = newRows.first(where: { $0.folderName == folder }) {
            pendingFolder = nil
            open(row.id)
        } else if let openRowID, newRows.contains(where: { $0.id == openRowID }) {
            refreshFiles(keepSelection: true)
        } else {
            openRowID = nil
            if let first = newRows.first { open(first.id) } else { clearReader() }
        }
        clampRailIndex()
        scheduleTitleGeneration()
    }

    /// Read every session's title files, `session.json`, and file list.
    /// Runs on a background task; no state is touched here.
    nonisolated static func loadRows(limit: Int) -> (rows: [Row], map: VaultMeetingTitleMap) {
        let databases = VaultPaths.preferredDatabasesDirectory()
        let meetings = databases?.appendingPathComponent("meetings", isDirectory: true)
        let map = meetings.map { VaultMeetingTitleMap.build(meetingsDirectory: $0) } ?? .empty
        let sessions = SessionArchive.recentSessions(limit: limit)
        return (sessions.map { makeRow($0, titleMap: map, databases: databases) }, map)
    }

    nonisolated static func makeRow(
        _ session: SessionArchive.ArchivedSession,
        titleMap: VaultMeetingTitleMap,
        databases: URL?
    ) -> Row {
        var row = makeBareRow(session, titleMap: titleMap)
        let fm = FileManager.default
        row.hasTranscript = fm.fileExists(atPath: session.transcriptURL.path)
        row.hasSummary = session.isRTIArchive && fm.fileExists(atPath: session.url.appendingPathComponent("summary.md").path)
        row.hasRetainedAudio = session.isRTIArchive && !TranscriptUpgradeService.audioInputs(in: session.url).isEmpty
        if row.hasTranscript, let databases {
            let base = databases.standardizedFileURL.path
            let path = session.transcriptURL.standardizedFileURL.path
            if path.hasPrefix(base + "/") { row.vaultTranscriptPath = String(path.dropFirst(base.count + 1)) }
        }
        return row
    }

    nonisolated private static func makeBareRow(_ session: SessionArchive.ArchivedSession, titleMap: VaultMeetingTitleMap) -> Row {
        let fm = FileManager.default
        guard session.isRTIArchive else {
            // A legacy recorded meeting: its sidecar name, unless generic.
            let stamp = session.date.map(canonicalStamp(for:))
            let bytes = (try? fm.attributesOfItem(atPath: session.transcriptURL.path))?[.size] as? Int
            let named = session.title == "Recorded meeting" ? nil : session.title
            let inputs = SessionTitleInputs(
                titleFile: named,
                vaultNoteTitle: stamp.flatMap(titleMap.title(forStamp:)),
                transcriptHead: transcriptHead(of: session.transcriptURL),
                startedAt: session.date,
                transcriptBytes: bytes
            )
            return Row(
                session: session,
                title: SessionTitleResolver.resolve(inputs),
                durationSeconds: nil, project: nil, mode: nil, speakerNames: [],
                stamp: stamp, hasNotes: false,
                transcriptStatus: bytes == nil ? "No transcript" : nil
            )
        }

        let dir = session.url
        let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        func read(_ name: String) -> String? {
            guard names.contains(name) else { return nil }
            return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        let metadata = read("session.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SessionArchiveMetadata.self, from: $0) }
        let speakers = read("speaker-names.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            .map { $0.values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted() } ?? []
        let stamp = VaultMeetingTitleMap.canonicalStamp(fromFolderName: dir.lastPathComponent)
        let bytes = names.contains("transcript.md")
            ? (try? fm.attributesOfItem(atPath: session.transcriptURL.path))?[.size] as? Int
            : nil
        let inputs = SessionTitleInputs(
            titleFile: read(SessionTitleResolver.titleFileName),
            hasManualMarker: names.contains(SessionTitleResolver.manualMarkerFileName),
            generatedMarker: read(SessionTitleResolver.generatedMarkerFileName),
            vaultNoteTitle: stamp.flatMap(titleMap.title(forStamp:)),
            calendarTitle: metadata?.calendarTitle,
            transcriptHead: transcriptHead(of: session.transcriptURL),
            startedAt: session.date,
            durationSeconds: metadata?.durationSeconds,
            transcriptBytes: bytes
        )
        return Row(
            session: session,
            title: SessionTitleResolver.resolve(inputs),
            durationSeconds: metadata?.durationSeconds,
            project: metadata?.workstream,
            mode: metadata?.mode,
            speakerNames: speakers,
            stamp: stamp,
            hasNotes: names.contains("notes.md"),
            transcriptStatus: SessionsWindowRules.transcriptStatus(fileNames: names),
            summaryStatus: SessionsWindowRules.summaryStatus(fileNames: names)
        )
    }

    /// Bytes read from the head of a transcript for its opening line. A
    /// transcript runs to 150 KB; the first spoken line is in the first few
    /// hundred bytes, so never read more than this.
    nonisolated static let transcriptHeadByteLimit = 8 * 1024

    /// A bounded head of `transcript.md`, for `SessionTitleResolver`'s
    /// first-substantive-line title. Nil when there is no transcript.
    nonisolated private static func transcriptHead(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: transcriptHeadByteLimit), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func canonicalStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Generated titles (rule 5, lazy, one at a time)

    private func scheduleTitleGeneration() {
        guard dependencies.generateTitle != nil, titleTask == nil else { return }
        titleTask = Task { [weak self] in
            await self?.generateMissingTitles()
            self?.titleTask = nil
        }
    }

    private func generateMissingTitles() async {
        while let row = rows.first(where: {
            $0.session.isRTIArchive
                && SessionTitleResolver.wantsGeneratedTitle($0.title, hasNotes: $0.hasNotes)
                && !titleAttempts.contains($0.id)
        }), let generate = dependencies.generateTitle {
            titleAttempts.insert(row.id)
            let notesURL = row.session.url.appendingPathComponent("notes.md")
            guard let notes = try? String(contentsOf: notesURL, encoding: .utf8),
                  let title = await generate(notes) else { continue }
            dependencies.persistGeneratedTitle(title, row.session.url)
            if let index = rows.firstIndex(where: { $0.id == row.id }),
               rows[index].title.source == .fallback || rows[index].title.source == .transcriptLine {
                rows[index].title = ResolvedSessionTitle(text: title, source: .generated)
            }
        }
    }

    // MARK: - Opening

    /// Open a session in the reader.
    func open(_ rowID: String) {
        guard rows.contains(where: { $0.id == rowID }) else { return }
        let changed = openRowID != rowID
        openRowID = rowID
        if let index = railRows.firstIndex(where: { $0.id == rowID }) { railIndex = index }
        if changed {
            isEditingSummary = false
            isEditingTranscript = false
            refreshFiles(keepSelection: false)
        }
    }

    /// Deep link (the "Notes ready" control, a notification tap): open that
    /// folder with the list hidden. Waits for the list if it is not loaded.
    func open(folder: String) {
        setRailVisible(false, remember: false)
        if let row = rows.first(where: { $0.folderName == folder }) {
            open(row.id)
            selectFile(named: files.first?.name)
        } else {
            pendingFolder = folder
        }
    }

    /// Open the row the rail highlights and hand focus back to the reader.
    func openHighlighted() {
        let list = railRows
        guard list.indices.contains(railIndex) else { return }
        open(list[railIndex].id)
    }

    func openRow(number: Int) -> Bool {
        let list = railRows
        guard (1...9).contains(number), list.indices.contains(number - 1) else { return false }
        railIndex = number - 1
        open(list[number - 1].id)
        return true
    }

    // MARK: - Rail

    func toggleRail() {
        setRailVisible(!isRailVisible, remember: true)
        if isRailVisible { railFocusRequest += 1 }
    }

    func setRailVisible(_ visible: Bool, remember: Bool) {
        isRailVisible = visible
        if remember { UserDefaults.standard.set(visible, forKey: Self.railVisibleKey) }
        if !visible {
            if actionsPlacement == .rail { closeActions() }
            if renamingRowID != nil { cancelRename() }
            if focus == .railSearch { focus = .none }
        }
    }

    func moveRailHighlight(_ delta: Int) {
        let count = railRows.count
        guard count > 0 else { return }
        railIndex = min(max(railIndex + delta, 0), count - 1)
    }

    private func clampRailIndex() {
        let count = railRows.count
        railIndex = count == 0 ? 0 : min(max(railIndex, 0), count - 1)
    }

    private func railQueryChanged() {
        railIndex = 0
        contentSearchTask?.cancel()
        contentSnippets = [:]
        contentOnlyIDs = []
        let query = railQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= SessionsWindowRules.minimumContentQueryLength else {
            contentSearchState = .idle
            return
        }
        guard let search = dependencies.contentSearch else {
            contentSearchState = .unavailable
            return
        }
        contentSearchState = .searching
        contentSearchTask = Task { [weak self] in
            try? await Task.sleep(for: SessionsWindowRules.contentSearchDelay)
            guard !Task.isCancelled else { return }
            let results = await search(query)
            guard !Task.isCancelled else { return }
            self?.applyContentResults(results, for: query)
        }
    }

    /// Map vault search results onto sessions (tier 2). Results outside RTI
    /// sessions and the meetings folder are dropped.
    func applyContentResults(_ results: [VaultSearch.Result]?, for query: String) {
        guard railQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        guard let results else {
            contentSearchState = .unavailable
            return
        }
        let byStamp = Dictionary(rows.compactMap { row in row.stamp.map { ($0, row.id) } }, uniquingKeysWith: { first, _ in first })
        var snippets: [String: SessionSnippet] = [:]
        var order: [String] = []
        for result in results {
            guard let stamp = SessionsWindowRules.sessionStamp(forResultPath: result.relativePath, noteStamps: titleMap.stampsByFileName),
                  let rowID = byStamp[stamp], snippets[rowID] == nil else { continue }
            let label = SessionsWindowRules.snippetLabel(forPath: result.relativePath)
            let snippet = SessionsWindowRules.snippet(label: label, text: result.excerpt, query: query)
                ?? SessionSnippet(label: label, runs: [.init(text: String(result.excerpt.prefix(SessionsWindowRules.snippetContext * 2)), isMatch: false)])
            snippets[rowID] = snippet
            order.append(rowID)
        }
        contentSnippets = snippets
        contentOnlyIDs = order
        contentSearchState = .done
    }

    // MARK: - Rename (inline, in the row)

    func beginRename(_ rowID: String) {
        guard let row = rows.first(where: { $0.id == rowID }), row.session.isRTIArchive else { return }
        if !isRailVisible { setRailVisible(true, remember: false) }
        closeActions()
        renamingRowID = rowID
        renameText = row.isFallbackTitle ? "" : row.title.text
        renameFocusRequest += 1
    }

    func commitRename() {
        guard let rowID = renamingRowID, let row = rows.first(where: { $0.id == rowID }) else { return }
        let dir = row.session.url
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleURL = dir.appendingPathComponent(SessionTitleResolver.titleFileName)
        let manualURL = dir.appendingPathComponent(SessionTitleResolver.manualMarkerFileName)
        if title.isEmpty {
            try? FileManager.default.removeItem(at: titleURL)
            try? FileManager.default.removeItem(at: manualURL)
        } else {
            try? title.write(to: titleURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: titleURL.path)
            FileManager.default.createFile(atPath: manualURL.path, contents: nil)
        }
        renamingRowID = nil
        if focus == .rename { focus = .none }
        if let index = rows.firstIndex(where: { $0.id == rowID }) {
            rows[index] = Self.makeRow(rows[index].session, titleMap: titleMap, databases: VaultPaths.preferredDatabasesDirectory())
        }
    }

    func cancelRename() {
        renamingRowID = nil
        renameText = ""
        if focus == .rename { focus = .none }
    }

    // MARK: - Actions

    func actions(for row: Row) -> [SessionAction] {
        let isOpen = row.id == openRowID
        return SessionAction.allCases.filter { action in
            switch action {
            case .ask:
                return row.vaultTranscriptPath != nil
            case .rename, .nameSpeakers:
                return row.session.isRTIArchive
            case .editTranscript:
                return row.session.isRTIArchive && row.hasTranscript
            case .editSummary:
                return row.hasSummary
            case .upgradeTranscript:
                return row.hasRetainedAudio && upgradingRowID == nil
            case .regenerateSummary:
                return row.session.isRTIArchive && row.hasTranscript && regeneratingRowID == nil
            case .copy, .saveMarkdown, .savePDF:
                return !isOpen || !fileText.isEmpty
            case .share:
                return dependencies.shareText != nil && (!isOpen || !fileText.isEmpty)
            case .trash:
                let coordinator = SessionCoordinator.shared
                let sameStart = coordinator.startedAt.flatMap { started in
                    row.session.date.map { abs(started.timeIntervalSince($0)) < 1 }
                } ?? false
                let active = coordinator.phase != .idle && coordinator.phase != .done && sameStart
                return row.session.isRTIArchive && dependencies.trashSession != nil && !isDeleting
                    && !active && upgradingRowID != row.id && regeneratingRowID != row.id
            case .revealInFinder:
                return true
            }
        }
    }

    /// Show the actions card for a row (or the open session).
    func showActions(for rowID: String? = nil, placement: ActionsPlacement) {
        guard let id = rowID ?? openRowID else { return }
        actionsRowID = id
        actionIndex = 0
        actionQuery = ""
        actionsPlacement = placement
    }

    func closeActions() {
        actionsPlacement = nil
        actionsRowID = nil
        actionQuery = ""
    }

    var actionsRow: Row? { rows.first { $0.id == actionsRowID } }

    var visibleActions: [SessionAction] {
        let actions = actionsRow.map(actions(for:)) ?? []
        guard !actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return actions }
        return actions.enumerated().compactMap { index, action -> (Int, Int, SessionAction)? in
            guard let score = CommandRegistry.matchScore(query: actionQuery, title: action.title) else { return nil }
            return (score, index, action)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }

    func moveActionHighlight(_ delta: Int) {
        let count = visibleActions.count
        guard count > 0 else { return }
        actionIndex = (actionIndex + delta + count) % count
    }

    func performHighlightedAction() {
        let list = visibleActions
        guard list.indices.contains(actionIndex), let id = actionsRowID else { return }
        perform(list[actionIndex], rowID: id)
    }

    /// Run an action on a row. A row that is not open opens first, so the
    /// action works on what the reader shows.
    func perform(_ action: SessionAction, rowID: String? = nil) {
        guard let id = rowID ?? openRowID, let row = rows.first(where: { $0.id == id }) else { return }
        closeActions()
        guard actions(for: row).contains(action) else { return }
        if action != .rename { open(id) }
        switch action {
        case .ask: askInRTI(row)
        case .rename: beginRename(id)
        case .nameSpeakers:
            loadSpeakerSuggestions()
            isSpeakerEditorPresented = true
        case .editTranscript:
            selectFile(named: "transcript")
            transcriptTurns = SessionTranscriptReview.turns(from: rawText(of: "transcript") ?? "")
            isEditingSummary = false
            isEditingTranscript = true
        case .editSummary:
            selectFile(named: "summary")
            summaryDraft = fileText
            isEditingTranscript = false
            isEditingSummary = true
        case .upgradeTranscript:
            pendingUpgradeRowID = id
            isUpgradeChoicePresented = true
        case .regenerateSummary: regenerateSummary(row)
        case .copy:
            NSPasteboard.copyMarkdownRich(fileText)
            notice = (id, "Copied as Markdown")
        case .share: dependencies.shareText?(fileText)
        case .trash:
            pendingDeletionRowID = id
            isDeleteConfirmationPresented = true
        case .saveMarkdown: exportMarkdown()
        case .savePDF: exportPDF()
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([row.session.url])
        }
    }

    func cancelDeletion() {
        isDeleteConfirmationPresented = false
        pendingDeletionRowID = nil
    }

    func confirmDeletion() {
        guard pendingDeletionRowID != nil else { return }
        isDeleteConfirmationPresented = false
        deletionRequest = UUID()
    }

    /// Called by the view's structured task only after explicit confirmation.
    func deleteConfirmedSession() async {
        guard deletionRequest != nil, let id = pendingDeletionRowID,
              let row = rows.first(where: { $0.id == id }), actions(for: row).contains(.trash),
              let trash = dependencies.trashSession else { return }
        isDeleting = true
        playback.pause()
        defer { isDeleting = false; pendingDeletionRowID = nil; deletionRequest = nil }
        do {
            try await trash(row.session.url)
            await reload()
            if let openRowID { notice = (openRowID, "Session moved to Trash. Restore it in Finder if needed.") }
        } catch {
            notice = (id, error.localizedDescription)
        }
    }

    // MARK: - Keys

    /// Run a window key. Returns false when nothing wanted it, so the event
    /// goes on to the focused view.
    func handle(_ command: SessionsWindowCommand) -> Bool {
        let editing = isEditingSummary || isEditingTranscript
        switch command {
        case .toggleList:
            toggleRail()
            return true
        case .find:
            showFind()
            return true
        case .findNext:
            guard isFindPresented else { return false }
            findNext()
            return true
        case .findPrevious:
            guard isFindPresented else { return false }
            findPrevious()
            return true
        case .actions:
            if actionsPlacement != nil {
                closeActions()
            } else {
                let fromRail = isRailVisible && focus == .railSearch
                let rowID = fromRail ? railRows[safe: railIndex]?.id : openRowID
                showActions(for: rowID, placement: fromRail ? .rail : .header)
            }
            return true
        case .ask:
            guard let row = openRow, actions(for: row).contains(.ask) else { return false }
            perform(.ask)
            return true
        case .rename:
            guard !editing, let id = (isRailVisible && focus == .railSearch) ? railRows[safe: railIndex]?.id : openRowID else { return false }
            beginRename(id)
            return true
        case .copy, .saveMarkdown:
            guard !editing, openRow != nil, !fileText.isEmpty else { return false }
            perform(command == .copy ? .copy : .saveMarkdown)
            return true
        case .close:
            return false
        case let .openRow(number):
            return openRow(number: number)
        case .escape:
            return popLayer()
        case .moveUp, .moveDown:
            let delta = command == .moveUp ? -1 : 1
            if actionsPlacement != nil {
                moveActionHighlight(delta)
                return true
            }
            if focus == .railSearch {
                moveRailHighlight(delta)
                return true
            }
            return false
        case .confirm, .confirmAlternate:
            if actionsPlacement != nil {
                performHighlightedAction()
                return true
            }
            if focus == .find {
                command == .confirm ? findNext() : findPrevious()
                return true
            }
            if focus == .railSearch {
                openHighlighted()
                return true
            }
            return false
        }
    }

    /// `esc` pops one layer: the actions card, the rename field, the find
    /// bar, the rail's search text, then the rail. It never closes the
    /// window.
    func popLayer() -> Bool {
        if actionsPlacement != nil {
            closeActions()
        } else if renamingRowID != nil {
            cancelRename()
        } else if isFindPresented {
            closeFind()
        } else if isRailVisible, !railQuery.isEmpty {
            railQuery = ""
        } else if isRailVisible, focus == .railSearch {
            setRailVisible(false, remember: true)
        } else {
            return false
        }
        return true
    }

    // MARK: - Files and reader

    func selectFile(named name: String?) {
        guard let name, let file = files.first(where: { $0.name == name }) else { return }
        select(file)
    }

    func select(_ file: SessionFile) {
        guard selectedFile != file else { return }
        selectedFile = file
        isEditingSummary = false
        isEditingTranscript = false
        loadText()
    }

    /// Preferred reading order; screenshots and the processor log follow.
    private static let fileOrder = [
        "summary.md", "live-intelligence.md", "notes.md", "transcript.md",
        "chat.md", "discussion-guide.md", "screen-context.md",
    ]

    private func refreshFiles(keepSelection: Bool) {
        guard let row = openRow else { clearReader(); return }
        let previous = selectedFile?.name
        files = Self.files(for: row.session)
        loadSpeakerNames()
        let keep = keepSelection ? files.first(where: { $0.name == previous }) : nil
        selectedFile = keep ?? files.first
        loadText()
    }

    private func clearReader() {
        files = []
        selectedFile = nil
        fileText = ""
        document = .empty
        speakerNames = [:]
        recomputeFindHits()
    }

    static func files(for session: SessionArchive.ArchivedSession) -> [SessionFile] {
        guard session.isRTIArchive else {
            return [SessionFile(url: session.transcriptURL, name: "transcript")]
        }
        let fm = FileManager.default
        let present = Set((try? fm.contentsOfDirectory(atPath: session.url.path)) ?? [])
        var loaded = fileOrder.filter(present.contains).map {
            SessionFile(url: session.url.appendingPathComponent($0), name: String($0.dropLast(3)))
        }
        let framesDir = session.url.appendingPathComponent("frames", isDirectory: true)
        if let frames = try? fm.contentsOfDirectory(atPath: framesDir.path),
           frames.contains(where: { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            loaded.append(SessionFile(url: framesDir, name: "frames"))
        }
        if let startedAt = session.date {
            let log = SessionArchive.processingLogURL(forSessionStartedAt: startedAt)
            if fm.fileExists(atPath: log.path) {
                loaded.append(SessionFile(url: log, name: "log"))
            }
        }
        return loaded
    }

    private func rawText(of name: String) -> String? {
        guard let file = files.first(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

    private func loadText() {
        guard let file = selectedFile else {
            fileText = ""
            document = .empty
            recomputeFindHits()
            return
        }
        if file.name == "frames" {
            fileText = ""
            document = .frames(file.url)
            recomputeFindHits()
            return
        }
        var text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? "(couldn't read file)"
        // Hide the machine-facing frontmatter block from the reading view.
        if text.hasPrefix("---"), let end = text.range(of: "\n---\n") {
            text = String(text[end.upperBound...])
        }
        fileText = applyingSpeakerNames(to: text)
        document = Self.document(for: file.name, text: fileText)
        findIndex = 0
        recomputeFindHits()
    }

    static func document(for name: String, text: String) -> ReaderDocument {
        switch name {
        case "transcript":
            return .transcript(SessionTranscriptReview.turns(from: text))
        case "chat":
            let turns = ArchivedChat.turns(fromMarkdown: text)
            return turns.isEmpty ? .markdown(SessionsWindowRules.markdownBlocks(text)) : .chat(turns)
        case "live-intelligence":
            return .intelligence(ArchivedFinding.parse(text))
        case "log":
            return .log(text)
        case "summary":
            if let split = summarySplit(text) {
                return .summary(
                    brief: SessionsWindowRules.markdownBlocks(split.brief),
                    record: SessionsWindowRules.markdownBlocks(split.record)
                )
            }
            return .markdown(SessionsWindowRules.markdownBlocks(text))
        default:
            return .markdown(SessionsWindowRules.markdownBlocks(text))
        }
    }

    /// The two-part summary (`=== SHARE BRIEF ===` / `=== FULL RECORD ===`).
    /// Nil when the marker is absent: legacy summaries render unsplit.
    static func summarySplit(_ text: String) -> (brief: String, record: String)? {
        guard let recordRange = text.range(of: "=== FULL RECORD ===") else { return nil }
        var brief = String(text[..<recordRange.lowerBound])
        if let briefMarker = brief.range(of: "=== SHARE BRIEF ===") {
            brief = String(brief[briefMarker.upperBound...])
        }
        brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = String(text[recordRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return nil }
        return (brief, record)
    }

    // MARK: - Speakers

    private func loadSpeakerNames() {
        guard let row = openRow, row.session.isRTIArchive,
              let data = try? Data(contentsOf: row.session.url.appendingPathComponent("speaker-names.json")),
              let names = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            speakerNames = [:]
            return
        }
        // Legacy files are keyed by raw ids (`remote_1`) from live renames;
        // current files by display labels. Normalize so both render.
        speakerNames = SpeakerLabelMapping.displayKeyedNames(names)
    }

    private func applyingSpeakerNames(to text: String) -> String {
        speakerNames
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key.count > $1.key.count }
            .reduce(text) { result, pair in
                result.replacingOccurrences(of: pair.key, with: pair.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// Anonymous speaker labels in the open transcript, for the editor.
    var speakerLabels: [String] {
        guard let row = openRow else { return [] }
        let text = (try? String(contentsOf: row.session.transcriptURL, encoding: .utf8)) ?? ""
        return SpeakerLabelMapping.archivedSpeakerLabels(in: text)
    }

    func speakerName(for label: String) -> String { speakerNames[label, default: ""] }

    func setSpeakerName(_ name: String, for label: String) { speakerNames[label] = name }

    private func loadSpeakerSuggestions() {
        guard let row = openRow, row.session.isRTIArchive,
              let file = SpeakerSuggestions.load(fromSessionDir: row.session.url)
        else {
            speakerSuggestions = [:]
            return
        }
        speakerSuggestions = file.speakers.reduce(into: [:]) { $0[$1.label] = $1 }
    }

    func saveSpeakerNames() {
        guard let row = openRow else { return }
        let names = speakerNames.reduce(into: [String: String]()) { result, pair in
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { result[pair.key] = name }
        }
        let url = row.session.url.appendingPathComponent("speaker-names.json")
        if names.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Save is the human confirm: let the vault enroll these voices so
            // future sessions get suggestions automatically.
            SpeakerEnrollment.fireAndForget(sessionDir: row.session.url)
        }
        speakerNames = names
        isSpeakerEditorPresented = false
        loadText()
    }

    func cancelSpeakerEditor() {
        isSpeakerEditorPresented = false
        loadSpeakerNames()
    }

    // MARK: - Editors

    func saveSummary() {
        guard let file = selectedFile, file.name == "summary" else { return }
        let original = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        let frontmatter: String
        if original.hasPrefix("---"), let end = original.range(of: "\n---\n") {
            frontmatter = String(original[..<end.upperBound])
        } else {
            frontmatter = ""
        }
        let content = frontmatter + summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? content.write(to: file.url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        isEditingSummary = false
        loadText()
    }

    func saveTranscript() {
        guard let file = selectedFile, file.name == "transcript",
              let original = try? String(contentsOf: file.url, encoding: .utf8)
        else { return }
        let updated = SessionTranscriptReview.replacingTurns(in: original, with: transcriptTurns)
        try? updated.write(to: file.url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        isEditingTranscript = false
        loadText()
    }

    var transcriptSpeakerOptions: [String] {
        let direct = speakerNames.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(Set(transcriptTurns.filter { !$0.isNote }.map(\.speaker) + direct))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Long jobs

    var upgradeProviderChoices: [AsyncTranscriptProviderOption] {
        let active = AsyncTranscriptProviders.active
        return [active] + AsyncTranscriptProviders.all.filter { $0.id != active.id }
    }

    func upgradeProviderTitle(_ provider: AsyncTranscriptProviderOption) -> String {
        if provider.id == AsyncTranscriptProviders.aliyun.id { return "Aliyun (Chinese-heavy)" }
        if provider.id == AsyncTranscriptProviders.soniox.id {
            return provider.id == AsyncTranscriptProviders.active.id ? "Soniox (default)" : "Soniox"
        }
        return provider.displayName
    }

    func cancelUpgradeChoice() {
        pendingUpgradeRowID = nil
        isUpgradeChoicePresented = false
    }

    func startTranscriptUpgrade(provider: AsyncTranscriptProviderOption) {
        guard let id = pendingUpgradeRowID, let row = rows.first(where: { $0.id == id }) else { return }
        pendingUpgradeRowID = nil
        upgradingRowID = id
        notice = (id, "Starting the transcript upgrade with \(provider.displayName)…")
        let session = row.session
        let report: @Sendable (TranscriptUpgradeProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.notice = (id, progress.message)
                if progress.isTerminal { self?.upgradingRowID = nil }
            }
        }
        Task { [weak self] in
            do {
                let result = try await TranscriptUpgradeService.upgrade(session: session, provider: provider, progress: report)
                guard let self else { return }
                SessionArchive.clearAutomaticUpgradePending(in: session.url)
                self.notice = (id, result.summaryURL == nil
                    ? "Transcript upgraded with \(result.provider). The summary did not regenerate."
                    : "Transcript upgraded with \(result.provider). Summary regenerated.")
                self.upgradingRowID = nil
                await self.reload()
                self.open(id)
                self.selectFile(named: "transcript")
            } catch {
                self?.notice = (id, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self?.upgradingRowID = nil
            }
        }
    }

    private func regenerateSummary(_ row: Row) {
        guard row.session.isRTIArchive, var transcript = try? String(contentsOf: row.session.transcriptURL, encoding: .utf8) else { return }
        if transcript.hasPrefix("---"), let end = transcript.range(of: "\n---\n") {
            transcript = String(transcript[end.upperBound...])
        }
        let id = row.id
        regeneratingRowID = id
        notice = (id, "Regenerating the summary…")
        let names = speakerNames
        let session = row.session
        Task { [weak self] in
            let summaryURL = await SessionArchive.writeAutoSummary(
                transcriptText: transcript,
                to: session.url,
                startedAt: session.date ?? Date(),
                speakerNames: names
            )
            guard let self else { return }
            self.regeneratingRowID = nil
            self.notice = (id, summaryURL == nil ? "The summary did not regenerate. Try again later." : "Summary regenerated.")
            guard summaryURL != nil else { return }
            await self.reload()
            self.open(id)
            self.selectFile(named: "summary")
        }
    }

    /// The notice line for the open session, and whether a job still runs.
    var openNotice: (text: String, isRunning: Bool)? {
        guard let notice, notice.rowID == openRowID else { return nil }
        return (notice.text, upgradingRowID == notice.rowID || regeneratingRowID == notice.rowID)
    }

    // MARK: - Ask and export

    /// Show the overlay's Assist tab with this session's transcript attached
    /// as an `@` mention. The Sessions window itself never answers.
    private func askInRTI(_ row: Row) {
        guard let path = row.vaultTranscriptPath else { return }
        WindowCoordinator.shared.showOverlay()
        NotificationCenter.default.post(name: .rtiSelectTab, object: "assist")
        NotificationCenter.default.post(name: .rtiSeedChatMention, object: path)
    }

    private var exportBaseName: String {
        let stamp = openRow?.session.displayName
            .replacingOccurrences(of: " · ", with: "-")
            .replacingOccurrences(of: ":", with: "") ?? "session"
        return "rti-\(selectedFile?.name ?? "session")-\(stamp)"
    }

    private func exportMarkdown() {
        guard selectedFile != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Render the Markdown to a paginated PDF through NSAttributedString.
    private func exportPDF() {
        guard selectedFile != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + ".pdf"
        panel.allowedContentTypes = [.pdf]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Self.writePDF(markdown: content, to: url)
            }
        }
    }

    private static func writePDF(markdown: String, to url: URL) {
        let attributed = (try? NSAttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? NSAttributedString(string: markdown)
        let page = NSPrintInfo()
        let margin = House.Spacing.xxl + House.Spacing.xxs
        page.topMargin = margin
        page.bottomMargin = margin
        page.leftMargin = margin
        page.rightMargin = margin
        let width = page.paperSize.width - 2 * margin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: page.paperSize.height - 2 * margin))
        textView.textStorage?.setAttributedString(attributed)
        textView.font = .systemFont(ofSize: House.TypeToken.Size.caption)
        page.jobDisposition = .save
        page.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: textView, printInfo: page)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
}

// MARK: - Archived findings

/// One `live-intelligence.md` item, parsed for the reader.
struct ArchivedFinding: Identifiable, Equatable {
    let id: Int
    let tag: String
    let timestamp: String
    let headline: String
    var matters: String = ""
    var quote: String?
    var speaker: String?

    var searchText: String {
        ([headline, matters, quote ?? ""]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func parse(_ markdown: String) -> [ArchivedFinding] {
        let headlinePattern = #"^- \*\*\[([^\]]+)\]\*\* `([^`]+)` (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: headlinePattern) else { return [] }
        var result: [ArchivedFinding] = []
        var current: ArchivedFinding?

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let tagRange = Range(match.range(at: 1), in: trimmed),
               let timeRange = Range(match.range(at: 2), in: trimmed),
               let headlineRange = Range(match.range(at: 3), in: trimmed) {
                if let current { result.append(current) }
                current = ArchivedFinding(
                    id: result.count,
                    tag: String(trimmed[tagRange]),
                    timestamp: String(trimmed[timeRange]),
                    headline: String(trimmed[headlineRange])
                )
            } else if trimmed.hasPrefix("- _Why:_ "), current != nil {
                current?.matters = String(trimmed.dropFirst("- _Why:_ ".count))
            } else if trimmed.hasPrefix("- > "), current != nil {
                let evidence = String(trimmed.dropFirst("- > ".count))
                if let split = evidence.range(of: ": ") {
                    current?.speaker = String(evidence[..<split.lowerBound])
                    current?.quote = String(evidence[split.upperBound...])
                } else {
                    current?.quote = evidence
                }
            }
        }
        if let current { result.append(current) }
        return result
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
