import AppKit
import Observation
import RTICore
import UniformTypeIdentifiers
import HouseDesign

/// State behind the Sessions window: the list rail (titles, search, date
/// groups, row actions), the open session and its files, find, and the
/// editors. The window, its keys, and every render proof drive this one
/// object, so a proof can put the window in any state without a click.
///
/// Read-only over the archive except for what the old browser already
/// wrote: a manual title, speaker names, transcript edits, and a transcript
/// upgrade. It never touches the session writer or the recording path.
@MainActor
@Observable
final class SessionsWindowModel {
    // MARK: - Dependencies

    /// What the model reaches outside the archive. `live` in the app;
    /// render proofs pass their own (no network, no writes).
    struct Dependencies {
        /// Keyword content search over the notes folder (tier 2). Nil: the rail
        /// says "Content search unavailable" and filters titles only.
        var contentSearch: (@Sendable (String) async -> [VaultSearch.Result]?)?
        var now: @Sendable () -> Date
        var trashSession: (@Sendable (URL) async throws -> Void)? = nil
        var shareText: (@MainActor (String) -> Void)? = nil
        /// The saved-chat library (Chats mode). Nil: the pane says the
        /// library is unavailable instead of showing an empty one.
        var chatLibrary: ChatLibraryLocation? = nil

        /// The running app: keyword search, trash, and share. These
        /// switch off outside RTI's own bundle (a test runner), so no test
        /// can reach the network or write into an archive.
        static var live: Dependencies {
            var dependencies = Dependencies(
                contentSearch: nil,
                now: { Date() }
            )
            guard Bundle.main.bundleIdentifier == "com.tristan.rti.personal" else { return dependencies }
            let archiveActions = SessionArchiveActions()
            dependencies.trashSession = { directory in try await archiveActions.moveToTrash(directory) }
            dependencies.chatLibrary = ChatLibraryLocation.applicationDefault()
            dependencies.shareText = { text in
                guard let view = NSApp.keyWindow?.contentView else { return }
                NSSharingServicePicker(items: [text]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
            dependencies.contentSearch = { query in
                await Task.detached { VaultSearch.search(query: query) }.value
            }
            return dependencies
        }
    }

    // MARK: - State

    let dependencies: Dependencies
    let playback = SessionPlaybackModel()
    /// The saved chats (Chats mode). Its own object, so the meeting list's
    /// state and the chat library's state never touch each other.
    let chatLibrary: ChatLibraryModel
    @ObservationIgnored var onAsk: (() -> Void)?
    @ObservationIgnored var onOpenRelatedChat: ((String) -> Void)?
    /// Which library the window shows. Sessions keeps every meeting path
    /// exactly as it was.
    var mode: LibraryMode = .sessions
    var isWindowVisible = true
    var isDeleteConfirmationPresented = false
    var pendingDeletionRowID: String?
    var deletionRequest: UUID?
    var isDeleting = false
    var playbackDirectory: URL? {
        guard isWindowVisible, mode == .sessions, openRow?.hasRetainedAudio == true else { return nil }
        return openRow?.session.url
    }
    var deletionTitle: String { rows.first { $0.id == pendingDeletionRowID }?.title.text ?? "this session" }

    var rows: [Row] = []
    var titleMap: VaultMeetingTitleMap = .empty
    var hasLoaded = false
    var openRowID: String?

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
    var contentSnippets: [String: SessionSnippet] = [:]
    var contentOnlyIDs: [String] = []
    var contentSearchState: ContentSearchState = .idle

    var actionsPlacement: ActionsPlacement?
    var actionIndex = 0
    var actionQuery = "" { didSet { if actionQuery != oldValue { actionIndex = 0 } } }
    var actionsRowID: String?

    var renamingRowID: String?
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
    var findHits: [FindHit] = []
    var findHitsByBlock: [Int: [Range<String.Index>]] = [:]

    var focus: Focus = .none
    /// Bumped to ask a field to take focus (the view watches them).
    var railFocusRequest = 0
    var findFocusRequest = 0
    var renameFocusRequest = 0

    // The open session.
    var files: [SessionFile] = []
    var selectedFile: SessionFile?
    var fileText = ""
    var document: ReaderDocument = .empty
    var speakerNames: [String: String] = [:]

    // Editors and long jobs.
    var isEditingTranscript = false
    var transcriptTurns: [SessionTranscriptTurn] = []
    var isSpeakerEditorPresented = false
    var isUpgradeChoicePresented = false
    var pendingUpgradeRowID: String?
    var upgradingRowID: String?
    var notice: (rowID: String, text: String)?

    @ObservationIgnored var contentSearchTask: Task<Void, Never>?
    @ObservationIgnored var pendingFolder: String?
    @ObservationIgnored var isLoading = false
    @ObservationIgnored var reloadGeneration = 0

    static let railVisibleKey = "rti.sessions.railVisible"
    /// How many sessions the list loads.
    static let listLimit = 200

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        self.chatLibrary = ChatLibraryModel(location: dependencies.chatLibrary, now: dependencies.now)
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
        return parts.joined(separator: " · ")
    }

    /// Only explicit durable links connect a saved conversation to a session.
    var relatedChats: [ChatLibraryRow] {
        guard let sessionID = openRow?.sessionID else { return [] }
        return chatLibrary.rows.filter { row in
            chatLibrary.sessionLinksByID[row.id]?.contains {
                $0.kind == "rti-session" && $0.id == sessionID
            } == true
        }
    }

    struct ReadingOrigin: Equatable {
        let rowID: String
        let fileName: String?
        let railVisible: Bool
    }

    var readingOrigin: ReadingOrigin? {
        openRowID.map { ReadingOrigin(rowID: $0, fileName: selectedFile?.name, railVisible: isRailVisible) }
    }

    func restore(_ origin: ReadingOrigin) {
        guard rows.contains(where: { $0.id == origin.rowID }) else { return }
        open(origin.rowID)
        selectFile(named: origin.fileName)
        setRailVisible(origin.railVisible, remember: false)
    }

}
