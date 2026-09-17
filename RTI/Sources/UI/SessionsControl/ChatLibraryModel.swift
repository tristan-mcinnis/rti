import AppKit
import Foundation
import HouseChatCore
import Observation
import RTICore
import UniformTypeIdentifiers

/// Which library the Sessions window is showing. Sessions is the archived
/// meeting list; Chats is the saved conversations (RTI's `ChatThreadStore`)
/// and the dated legacy turn logs beside them.
enum LibraryMode: String, CaseIterable, Identifiable, Sendable {
    case sessions
    case chats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .chats: "Chats"
        }
    }

    /// The glyph the switch falls back to when the header runs out of room.
    var symbol: String {
        switch self {
        case .sessions: "clock.arrow.circlepath"
        case .chats: "bubble.left.and.text.bubble.right"
        }
    }
}

/// The Chats library: the saved chats list, the open chat, and the actions
/// the plan requires — search, rename, pin, resume, export, confirmed
/// deletion, and storage usage.
///
/// It reads through `ChatThreadStore` (an actor) and the legacy log reader
/// (an actor), so no file I/O runs on the main actor. It never reads the
/// user's original files: a source is checked against the store's own copy by
/// hash. It never reads the live composer, and never writes a meeting
/// artifact: the one boundary outward is `.rtiResumeChat`.
@MainActor
@Observable
final class ChatLibraryModel {
    /// Nil when RTI cannot resolve its vault or Application Support folder.
    /// The pane then says so instead of showing an empty library.
    let location: ChatLibraryLocation?

    private let legacyReader: ChatLibraryLegacyReader?
    private let now: @Sendable () -> Date

    // MARK: - List state

    private(set) var rows: [ChatLibraryRow] = []
    private(set) var legacyLogs: [ChatLibraryLegacy.Log] = []
    /// Days whose readable rows all belong to saved chats. Counted so the rail
    /// can say where those turns are listed instead of showing a duplicate day.
    private(set) var linkedLogDayCount = 0
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var errorText: String?
    private(set) var storageBytes: Int?

    var query = "" {
        didSet { if query != oldValue { notice = nil } }
    }

    // MARK: - Open state

    private(set) var openID: String?
    /// The dated legacy log on screen, when one is open instead of a chat.
    private(set) var openLogID: String?
    private(set) var detail: ChatLibraryDetail?
    private(set) var isLoadingDetail = false
    private(set) var detailError: String?

    // MARK: - Rename, pin, delete

    private(set) var renamingID: String?
    var renameText = ""
    private(set) var renameFocusRequest = 0
    private(set) var notice: String?
    var isDeleteConfirmationPresented = false
    private(set) var pendingDeletionID: String?
    private(set) var deletionRequest: UUID?
    private(set) var isDeleting = false

    @ObservationIgnored private var hasStarted = false

    init(location: ChatLibraryLocation?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.location = location
        self.legacyReader = location.map { ChatLibraryLegacyReader(root: $0.legacyTurnsRoot) }
        self.now = now
    }

    /// True when RTI has no resolvable chat store at all.
    var isUnavailable: Bool { location == nil }

    // MARK: - Derived list

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var sections: [(title: String, rows: [ChatLibraryRow])] {
        ChatLibraryRules.sections(rows: rows, query: query, isSearching: isSearching)
    }

    var railRows: [ChatLibraryRow] { sections.flatMap(\.rows) }

    /// The dated logs a query matches. A log matches on its day and on the
    /// text of its entries.
    var legacyMatches: [ChatLibraryLegacy.Log] {
        guard isSearching else { return legacyLogs }
        let terms = ChatLibraryRules.terms(query)
        return legacyLogs.filter { log in
            let text = ([log.title, log.day] + log.turns.flatMap { turn in
                [turn.question, turn.answer, turn.action ?? "", turn.mode ?? ""]
            }).joined(separator: "\n")
            return terms.allSatisfy { text.range(of: $0, options: ChatLibraryRules.foldOptions) != nil }
        }
    }

    var emptyText: String {
        ChatLibraryRules.emptyText(hasRows: !rows.isEmpty || !legacyLogs.isEmpty, isSearching: isSearching, hasLoaded: hasLoaded)
    }

    var openRow: ChatLibraryRow? { rows.first { $0.id == openID } }

    /// The row's second line, on this library's own clock, so a proof with a
    /// fixed clock reads the same in the rail and the header.
    func detail(for row: ChatLibraryRow) -> String {
        ChatLibraryRules.detail(for: row, now: now())
    }

    var openLog: ChatLibraryLegacy.Log? { legacyLogs.first { $0.id == openLogID } }

    /// Where the days that hold only saved-chat rows are listed. Nil when no
    /// day was left out.
    var linkedLogNote: String? {
        switch linkedLogDayCount {
        case 0:
            return nil
        case 1:
            return "1 day appears only as a saved chat. Its turns are listed above, not repeated as a dated log."
        default:
            return "\(linkedLogDayCount) days appear only as saved chats. Their turns are listed above, not repeated as dated logs."
        }
    }

    /// The header's title: the open chat, the open day, or the library.
    var headerTitle: String {
        if let log = openLog { return log.title }
        if let row = openRow { return row.title }
        return "Chats"
    }

    /// The header's second line.
    var headerLine: String {
        if let log = openLog {
            return ["Dated log", log.detailText].joined(separator: " · ")
        }
        if let row = openRow {
            return ChatLibraryRules.headerLine(for: row, now: now())
        }
        guard hasLoaded else { return "Loading chats…" }
        return storageLine ?? "\(rows.count) saved chat\(rows.count == 1 ? "" : "s")"
    }

    /// "12 saved chats · 1 dated log · 4.2 MB of saved copies". Nil until the
    /// store has answered.
    var storageLine: String? {
        ChatLibraryFormat.storageLine(chats: rows.count, legacyLogs: legacyLogs.count, bytes: storageBytes)
    }

    /// The same facts, short enough for the footer beside the actions.
    var compactStorageLine: String? {
        ChatLibraryFormat.compactStorageLine(chats: rows.count, legacyLogs: legacyLogs.count, bytes: storageBytes)
    }

    /// The footer's shorter variants, tried in order: at the window's minimum
    /// width the size is dropped whole, never clipped mid-number.
    var countsStorageLine: String {
        ChatLibraryFormat.countsLine(chats: rows.count, legacyLogs: legacyLogs.count)
    }

    var chatsStorageLine: String {
        ChatLibraryFormat.chatCount(rows.count)
    }

    var deletionTitle: String {
        rows.first { $0.id == pendingDeletionID }?.title ?? "this chat"
    }

    /// What the detail pane loads from: a chat id or a dated log's day.
    var selectionKey: String? {
        if let openLogID { return "log:\(openLogID)" }
        return openID
    }

    /// A damage or read failure the pane shows above whatever it could load.
    var detailNoticeText: String? {
        if let detailError { return detailError }
        if let issue = detail?.issue { return ChatLibraryRules.issueText(issue) + ": this chat could not be read. Its file is left in place." }
        return nil
    }

    // MARK: - Loading

    /// Load once, the first time Chats is shown.
    func loadIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await reload()
    }

    /// Read the store's summaries, every recorded chat, and the legacy logs.
    ///
    /// A chat is loaded in full so its pin (an app-only field the summaries
    /// do not carry) and its searchable text come from one pass. A failed
    /// read is reported and its row is kept, never dropped.
    func reload() async {
        hasStarted = true
        guard let location else {
            rows = []
            legacyLogs = []
            storageBytes = nil
            hasLoaded = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let summaries = try await location.store.summaries()
            var records: [ConversationRecord] = []
            for summary in summaries where summary.issue == nil {
                if let record = try? await location.store.load(id: summary.id) { records.append(record) }
            }
            rows = ChatLibraryRules.rows(records: records, summaries: summaries)
            storageBytes = try? await location.store.storageUsage()
            errorText = nil
        } catch {
            // An unreadable store is not an empty one: keep what is shown.
            errorText = "The chat library could not be read: \(error.localizedDescription)"
            hasLoaded = true
        }
        hasLoaded = true
        if let openID, !rows.contains(where: { $0.id == openID }) {
            self.openID = nil
            detail = nil
        }
        if let openLogID {
            // The legacy list is rebuilt below; keep the choice and drop it
            // only if that day is gone.
            self.openLogID = openLogID
        }
        await reloadLegacy()
    }

    private func reloadLegacy() async {
        guard let legacyReader else {
            legacyLogs = []
            linkedLogDayCount = 0
            return
        }
        let logs = await legacyReader.logs()
        // A day whose readable rows all belong to saved chats has nothing of
        // its own to show: those turns are already listed as chats, and
        // listing the day too would show one history twice.
        legacyLogs = logs.filter { !$0.isEntirelyProjected }
        linkedLogDayCount = logs.filter(\.isEntirelyProjected).count
        if let openLogID, !legacyLogs.contains(where: { $0.id == openLogID }) {
            self.openLogID = nil
        }
    }

    // MARK: - Selection

    func select(id: String) {
        openID = id
        openLogID = nil
        detail = nil
        detailError = nil
        notice = nil
    }

    func select(logID: String) {
        openLogID = logID
        openID = nil
        detail = nil
        detailError = nil
        notice = nil
    }

    /// Load the selection's record and check every source it points at. The
    /// view drives this from a structured task on the selection.
    func loadDetail() async {
        guard let location else { return }
        detailError = nil
        guard openLogID == nil else {
            detail = nil
            return
        }
        guard let id = openID else {
            detail = nil
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let record = try await location.store.load(id: id)
            let sources = await ChatLibraryRules.sources(for: record) { ref in
                await Self.check(ref, in: location)
            }
            guard openID == id else { return }
            detail = ChatLibraryDetail(id: id, record: record, issue: nil, sources: sources)
        } catch ConversationArchiveError.missing {
            guard openID == id else { return }
            detail = ChatLibraryDetail(id: id, record: nil, issue: nil, sources: [])
            detailError = "This chat's file is not there any more."
        } catch {
            guard openID == id else { return }
            detail = ChatLibraryDetail(id: id, record: nil, issue: .corrupt, sources: [])
            detailError = "This chat could not be read: \(error.localizedDescription) Its file is left in place."
        }
    }

    nonisolated private static func check(_ ref: ArtifactRef, in location: ChatLibraryLocation) async -> ChatLibrarySource.State {
        do {
            switch try await location.store.verify(ref) {
            case .verified: return .verified
            case .missing: return .missing
            case let .mismatched(actual): return .mismatched(actualSHA256: actual)
            }
        } catch {
            return .unverifiable("The saved copy could not be checked: \(error.localizedDescription)")
        }
    }

    // MARK: - Keys

    /// `esc` pops one layer in Chats: the rename field, then the query.
    func popLayer() -> Bool {
        if renamingID != nil {
            cancelRename()
        } else if !query.isEmpty {
            query = ""
        } else {
            return false
        }
        return true
    }

    // MARK: - Rename

    func beginRename(id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        renamingID = id
        renameText = row.titleIsStored ? row.title : ""
        renameFocusRequest += 1
    }

    func cancelRename() {
        renamingID = nil
        renameText = ""
    }

    /// Save the name. An empty field clears the name, and the row falls back
    /// to the first question rather than keeping a name nobody wrote.
    func commitRename() async {
        guard let id = renamingID, let location else { return }
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        renameText = ""
        do {
            // ChatThreadStore.rename(id:title:) — keep in step with the store.
            _ = try await location.store.rename(id: id, title: text.isEmpty ? nil : text)
            await reload()
            notice = text.isEmpty
                ? "Name cleared. The row shows the first question again."
                : "Chat renamed."
        } catch {
            notice = "The name could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Pin

    func togglePin(id: String) async {
        guard let location, let row = rows.first(where: { $0.id == id }) else { return }
        do {
            // ChatThreadStore.setPinned(id:_:) — keep in step with the store.
            _ = try await location.store.setPinned(id: id, !row.isPinned)
            await reload()
            notice = row.isPinned ? "Unpinned." : "Pinned."
        } catch {
            notice = "The pin could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Resume

    /// Continue a saved chat in RTI's own composer. The library never touches
    /// the composer itself: the id goes out as a notification, and the
    /// handler loads that thread (or starts one when nothing is stored).
    func resume(id: String) {
        select(id: id)
        showAssistSurface()
        ChatLibraryResume.resume(id: id)
        notice = "Opening this chat in RTI. Continue it there."
    }

    /// Reuse the open dated log in a new chat.
    ///
    /// The whole day goes across as a typed seed: every displayed entry, each
    /// with its own timestamp, as dated source material. It joins nothing and
    /// invents no boundary, and it sends nothing: the handler attaches the
    /// source and leaves the draft prompt editable.
    func openDatedLogAsNewChat() {
        guard let log = openLog, let seed = ChatLibraryDatedSeed.day(log) else { return }
        seedDatedChat(seed)
        notice = "Reusing \(seed.entries.count) dated entr\(seed.entries.count == 1 ? "y" : "ies") from \(log.title) in a new chat. Nothing is sent until you send it."
    }

    /// Reuse one dated entry in a new chat. One recorded turn is a real unit,
    /// so this needs no guess about where a conversation began.
    func useDatedEntryInNewChat(line: Int) {
        guard let log = openLog,
              let turn = log.turns.first(where: { $0.id == line }),
              let seed = ChatLibraryDatedSeed.entry(turn, in: log)
        else { return }
        seedDatedChat(seed)
        notice = "Reusing the \(turn.timeText) entry in a new chat. Nothing is sent until you send it."
    }

    private func seedDatedChat(_ seed: ChatLibraryDatedSeed) {
        showAssistSurface()
        ChatLibraryResume.seedDatedChat(seed)
    }

    private func showAssistSurface() {
        WindowCoordinator.shared.showOverlay()
        NotificationCenter.default.post(name: .rtiSelectTab, object: "assist")
    }

    // MARK: - Export

    func exportJSON(id: String) async {
        guard let location else { return }
        do {
            let data = try await location.store.export(id: id)
            let name = exportName(id: id, extension: "json")
            savePanel(name: name, type: UTType(filenameExtension: "json") ?? .json) { url in
                try? data.write(to: url)
            }
        } catch {
            notice = "The export failed: \(error.localizedDescription)"
        }
    }

    func exportMarkdown(id: String) async {
        guard let location else { return }
        do {
            let record = try await location.store.load(id: id)
            let text = ChatLibraryRules.markdown(for: record)
            let name = exportName(id: id, extension: "md")
            savePanel(name: name, type: UTType(filenameExtension: "md") ?? .plainText) { url in
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            notice = "The export failed: \(error.localizedDescription)"
        }
    }

    private func exportName(id: String, extension fileExtension: String) -> String {
        let title = rows.first { $0.id == id }?.title ?? "chat"
        var slug = ""
        var lastWasDash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
            if slug.count >= 40 { break }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "rti-chat-\(trimmed.isEmpty ? "chat" : trimmed).\(fileExtension)"
    }

    private func savePanel(name: String, type: UTType, write: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            write(url)
        }
    }

    // MARK: - Deletion

    /// Ask first. Nothing is removed until the user confirms in the alert.
    func requestDeletion(id: String) {
        pendingDeletionID = id
        isDeleteConfirmationPresented = true
    }

    func cancelDeletion() {
        isDeleteConfirmationPresented = false
        pendingDeletionID = nil
    }

    func confirmDeletion() {
        guard pendingDeletionID != nil else { return }
        isDeleteConfirmationPresented = false
        deletionRequest = UUID()
    }

    /// Delete the chat record and the saved copies only it owned.
    ///
    /// The store does the reference check: bytes another chat still points at
    /// are kept. Nothing here touches a meeting, a recording, a linked
    /// document, or the user's original file — the record's paths are
    /// references, and this library never reads or removes them.
    func deleteConfirmed() async {
        guard let location, deletionRequest != nil, let id = pendingDeletionID else { return }
        isDeleting = true
        defer {
            isDeleting = false
            pendingDeletionID = nil
            deletionRequest = nil
        }
        let wasOpen = openID == id
        do {
            // ChatThreadStore.delete(id:) — keep in step with the store.
            _ = try await location.store.delete(id: id)
            if wasOpen {
                openID = nil
                detail = nil
            }
            await reload()
            notice = "Chat deleted, with the saved copies only it owned. Linked meetings, recordings, and your own files are untouched."
        } catch {
            let stillStored = location.store.contains(id: id)
            notice = stillStored
                ? "The chat could not be deleted: \(error.localizedDescription)"
                : "The chat is gone, but some of its saved copies could not be cleaned up: \(error.localizedDescription)"
            await reload()
        }
    }
}

// MARK: - The window's own title

extension SessionsWindowModel {
    /// The header's title: the open session, the open chat, or the window's
    /// own name.
    var windowTitle: String {
        switch mode {
        case .sessions: openRow?.title.text ?? "Sessions"
        case .chats: chatLibrary.headerTitle
        }
    }

    /// The header's second line.
    var windowSubtitle: String {
        switch mode {
        case .sessions: headerLine
        case .chats: chatLibrary.headerLine
        }
    }

    /// Load the library the window is showing, once, when it is first shown.
    func loadActiveLibrary() async {
        guard mode == .chats else { return }
        await chatLibrary.loadIfNeeded()
    }
}
