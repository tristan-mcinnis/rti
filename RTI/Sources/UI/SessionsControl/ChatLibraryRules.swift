import Foundation
import HouseChatCore
import RTICore

/// Where the Chats library reads from: RTI's own durable chat store
/// (`ChatThreadStore`) and the legacy daily turn logs beside it. Injected, so
/// a test or a render proof never touches the live vault or the real
/// Application Support folder.
struct ChatLibraryLocation: Sendable {
    let store: ChatThreadStore
    /// `<vault>/databases/projects/personal/rti/turns`, read only.
    let legacyTurnsRoot: URL

    /// The running app's roots.
    ///
    /// The store is `ChatThreadStore.shared()`, the same instance the
    /// assistant writes through: a rename, a pin, or a deletion from the
    /// library is serialized with a streaming answer instead of racing a
    /// second store over the same files. Nil when RTI has no vault.
    static func applicationDefault() -> ChatLibraryLocation? {
        guard let store = try? ChatThreadStore.shared(),
              let rti = VaultPaths.rtiDirectory()
        else { return nil }
        return ChatLibraryLocation(
            store: store,
            legacyTurnsRoot: rti.appendingPathComponent("turns", isDirectory: true)
        )
    }
}

/// One saved chat as the Chats rail draws it.
///
/// Everything the rail needs is on the row: a chat is loaded once per refresh
/// so the pin (an `appPayload` field the summaries do not carry) and the
/// searchable text do not cost a second read.
struct ChatLibraryRow: Identifiable, Equatable, Sendable {
    let id: String
    /// The stored name, or the first question when the chat has no name.
    let title: String
    /// True when the title is the chat's own, not the first question.
    let titleIsStored: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let turnCount: Int
    let isPinned: Bool
    /// A file on disk that could not be read (or was written by a newer
    /// build). The row still shows, and it says so.
    let issue: ConversationIssue?
    let byteCount: Int?
    let surface: ChatSurface?
    /// The chat's own name and the text of every turn, for the rail search.
    /// Nothing else from a turn is kept in memory.
    let searchText: String
    /// True for a saved thread; false for a dated legacy log.
    var isLegacy: Bool { false }

    /// The title a chat with no name falls back to: its first question.
    static let untitled = "Untitled chat"
    /// How much of a first question a fallback title keeps.
    static let fallbackTitleLength = 60
}

/// One chat as the reader draws it: the stored record when it could be read,
/// and the state of every byte it points at.
struct ChatLibraryDetail: Equatable, Sendable {
    let id: String
    /// Nil when the file could not be read. The pane then says so and never
    /// invents turns.
    let record: ConversationRecord?
    let issue: ConversationIssue?
    let sources: [ChatLibrarySource]

    var turns: [TurnRecord] { record?.turns ?? [] }

    func source(for attachmentID: String) -> ChatLibrarySource? {
        sources.first { $0.id == attachmentID }
    }
}

/// One submitted source in a saved chat, and whether its archived bytes are
/// still there.
///
/// The library never reads the user's original file: the record keeps that
/// path as a reference, and every check runs against the store's own copy by
/// hash.
struct ChatLibrarySource: Identifiable, Equatable, Sendable {
    /// The attachment's id, so a turn can find its own sources.
    let id: String
    let name: String
    /// "PDF", "Screenshot", "Link", "Text"…
    let kindLabel: String
    let byteCount: Int?
    let pageCount: Int?
    /// SHA-256 of the original bytes. Nil for images, which are archived
    /// without one, and then the source says so.
    let contentHash: String?
    /// The file on this Mac the user attached. Shown, never read.
    let sourcePath: String?
    /// How many archived copies this attachment has (original, normalized
    /// image, extracted text).
    let archivedCopies: Int
    let state: State
    /// A trim or truncation note, when the record has one.
    let note: String?

    enum State: Equatable, Sendable {
        /// Every archived copy hashes to what the record says.
        case verified
        /// The record points at a copy that is not in the store.
        case missing
        /// A copy is there and hashes to something else.
        case mismatched(actualSHA256: String)
        /// The copy cannot be checked (an unknown artifact kind, or a read
        /// that failed). The reason is shown as written.
        case unverifiable(String)
        /// The record archived no bytes for this source at all.
        case noArchive
    }

    var stateText: String {
        switch state {
        case .verified: "Verified"
        case .missing: "Missing"
        case .mismatched: "Hash mismatch"
        case .unverifiable: "Unverifiable"
        case .noArchive: "No saved copy"
        }
    }

    /// The second line: what the state means for this source.
    var detailText: String {
        switch state {
        case .verified:
            archivedCopies == 1
                ? "One saved copy, present and matching."
                : "\(archivedCopies) saved copies, present and matching."
        case .missing:
            "The saved copy is gone. The original file is untouched."
        case let .mismatched(actual):
            "The saved copy hashes to \(ChatLibraryFormat.shortHash(actual)) instead."
        case let .unverifiable(reason):
            reason
        case .noArchive:
            "Nothing was archived for this source; only the record remains."
        }
    }

    /// "PDF · 1.2 MB · 12 pages". What the source is, not its state: the
    /// state line below says whether its copies are still there.
    var factsText: String {
        var parts = [kindLabel]
        if let byteCount { parts.append(ChatLibraryFormat.bytes(byteCount)) }
        if let pageCount { parts.append("\(pageCount) page\(pageCount == 1 ? "" : "s")") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// The pure rules behind the Chats library: what a row says, which rows a
/// query matches, how they are grouped, and what an export contains. No I/O
/// and no views, so every rule is testable on its own.
enum ChatLibraryRules {
    // MARK: - Rows

    /// Build the rail's rows from the store's records, newest first.
    ///
    /// `summaries` carry the file's byte count and the state of the file on
    /// disk. A summary with no record behind it keeps its row: a file that
    /// could not be read is reported, never hidden and never replaced.
    static func rows(
        records: [ConversationRecord],
        summaries: [ConversationSummary]
    ) -> [ChatLibraryRow] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let readable = records.map { row(from: $0, summary: byID[$0.id]) }
        let readableIDs = Set(readable.map(\.id))
        let unreadable = summaries.filter { !readableIDs.contains($0.id) }.map { summary -> ChatLibraryRow in
            let stored = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasStored = !(stored ?? "").isEmpty
            return ChatLibraryRow(
                id: summary.id,
                title: hasStored ? stored! : ChatLibraryRow.untitled,
                titleIsStored: hasStored,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt ?? summary.savedAt,
                turnCount: summary.turnCount,
                isPinned: false,
                issue: summary.issue,
                byteCount: summary.byteCount,
                surface: summary.surface,
                searchText: summary.title ?? ""
            )
        }
        return (readable + unreadable)
            .sorted { lhs, rhs in
                let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
                let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
    }

    static func row(from record: ConversationRecord, summary: ConversationSummary?) -> ChatLibraryRow {
        let stored = record.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStored = !(stored ?? "").isEmpty
        return ChatLibraryRow(
            id: record.id,
            title: hasStored ? stored! : fallbackTitle(for: record),
            titleIsStored: hasStored,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt ?? summary?.savedAt,
            turnCount: record.turns.count,
            isPinned: isPinned(record),
            issue: summary?.issue,
            byteCount: summary?.byteCount,
            surface: record.surface,
            searchText: searchText(for: record, title: hasStored ? stored! : fallbackTitle(for: record))
        )
    }

    /// The first question, trimmed to one line and one row's worth of text.
    static func fallbackTitle(for record: ConversationRecord) -> String {
        guard let question = record.turns.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty
        else { return ChatLibraryRow.untitled }
        let oneLine = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        guard oneLine.count > ChatLibraryRow.fallbackTitleLength else { return oneLine }
        return String(oneLine.prefix(ChatLibraryRow.fallbackTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A pin is app state the shared schema does not model: it rides in the
    /// record's `appPayload`, under the namespace and key the store documents
    /// (`ChatThreadStore.pinnedPayloadKey`), read through that one constant so
    /// the two sides cannot drift.
    static func isPinned(_ record: ConversationRecord) -> Bool {
        record.appPayload?[ChatThreadStore.pinnedPayloadKey]?.boolValue ?? false
    }

    static func searchText(for record: ConversationRecord, title: String) -> String {
        ([title] + record.turns.map(\.text)).joined(separator: "\n")
    }

    // MARK: - Sources

    /// One entry per source the chat carries, with the state of the copies
    /// the store owns.
    ///
    /// `check` is the store's own verification, injected so this stays a pure
    /// rule. Every check runs against the archived copy by hash; the record's
    /// `path` is shown as a reference and never read.
    static func sources(
        for record: ConversationRecord,
        check: @Sendable (ArtifactRef) async -> ChatLibrarySource.State
    ) async -> [ChatLibrarySource] {
        var sources: [ChatLibrarySource] = []
        for attachment in record.attachments {
            let refs = [
                attachment.artifacts?.original,
                attachment.artifacts?.normalizedImage,
                attachment.artifacts?.extractedText,
            ].compactMap { $0 }
            var state: ChatLibrarySource.State = refs.isEmpty ? .noArchive : .verified
            for ref in refs {
                guard ref.isReadable else {
                    state = .unverifiable("The record names a kind of copy this build cannot read (\(ref.kindRaw ?? ref.kind.rawValue)).")
                    break
                }
                let checked = await check(ref)
                guard checked == .verified else {
                    state = checked
                    break
                }
            }
            sources.append(ChatLibrarySource(
                id: attachment.id,
                name: attachment.name,
                kindLabel: kindLabel(attachment.kind),
                byteCount: attachment.byteCount,
                pageCount: attachment.pageCount,
                contentHash: attachment.contentHash,
                sourcePath: attachment.path,
                archivedCopies: refs.count,
                state: state,
                note: attachment.truncation?.summary
            ))
        }
        return sources
    }

    // MARK: - Grouping and the query

    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// True when every word of the query appears in the chat's own text.
    /// An empty query matches everything.
    static func matches(_ row: ChatLibraryRow, query: String) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { row.searchText.range(of: $0, options: foldOptions) != nil }
    }

    /// The query's words, lowercased, without empty pieces.
    static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Pinned first, then the rest. While a query is typed: one Results list,
    /// pinned chats still ahead.
    static func sections(
        rows: [ChatLibraryRow],
        query: String,
        isSearching: Bool
    ) -> [(title: String, rows: [ChatLibraryRow])] {
        let matched = rows.filter { matches($0, query: query) }
        guard !isSearching else {
            return matched.isEmpty ? [] : [("Results", matched)]
        }
        let pinned = matched.filter(\.isPinned)
        let rest = matched.filter { !$0.isPinned }
        return [("Pinned", pinned), ("Recent", rest)].filter { !$0.1.isEmpty }
    }

    /// True when there is nothing to show yet, rather than nothing matching:
    /// an empty library and an empty result say different things.
    static func emptyText(hasRows: Bool, isSearching: Bool, hasLoaded: Bool) -> String {
        guard hasLoaded else { return "Loading chats…" }
        guard hasRows else { return "No saved chats yet" }
        return isSearching ? "No chats match" : "No saved chats yet"
    }

    // MARK: - Row and header text

    /// The row's second line: the turn count, then the time today or the day
    /// before, and a word when the file on disk is damaged.
    static func detail(for row: ChatLibraryRow, now: Date, calendar: Calendar = .current) -> String {
        var parts = ["\(row.turnCount) turn\(row.turnCount == 1 ? "" : "s")"]
        let date = row.updatedAt ?? row.createdAt
        if let date { parts.append(SessionsWindowRules.dayOrTime(date, now: now, calendar: calendar)) }
        if let issue = row.issue { parts.append(issueText(issue)) }
        return parts.joined(separator: " · ")
    }

    /// The header's line for the open chat: the full day and time, the turn
    /// count, and the pin.
    static func headerLine(for row: ChatLibraryRow, now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        let date = row.updatedAt ?? row.createdAt
        if let date {
            parts.append("\(SessionsWindowRules.headerDay(date, now: now, calendar: calendar)) \(SessionsWindowRules.timeText(date, calendar: calendar))")
        }
        parts.append("\(row.turnCount) turn\(row.turnCount == 1 ? "" : "s")")
        if row.isPinned { parts.append("Pinned") }
        if let issue = row.issue { parts.append(issueText(issue)) }
        return parts.joined(separator: " · ")
    }

    /// What the row and the pane say about a file that could not be read.
    static func issueText(_ issue: ConversationIssue) -> String {
        switch issue {
        case .corrupt: "Damaged file"
        case .unsupportedSchema: "Newer format"
        case .unreadable: "Unreadable file"
        }
    }

    /// What a chat with no name says about its own title.
    static func titleNote(for row: ChatLibraryRow) -> String? {
        row.titleIsStored ? nil : "Named from the first question"
    }

    // MARK: - Export

    /// One chat as Markdown, in the same grammar the archived `chat.md` uses,
    /// so a reader sees one shape across both records.
    static func markdown(for record: ConversationRecord) -> String {
        var lines: [String] = ["# \(row(from: record, summary: nil).title)", ""]
        if let created = record.createdAt {
            lines.append("- Created: \(exportStamp(created))")
        }
        if let updated = record.updatedAt {
            lines.append("- Updated: \(exportStamp(updated))")
        }
        lines.append("- Turns: \(record.turns.count)")
        lines.append("- Chat ID: `\(record.id)`")
        if let surface = record.surface {
            lines.append("- Surface: `\(surface.rawValue)`")
        }
        if isPinned(record) { lines.append("- Pinned: yes") }
        for session in record.sessionLinks {
            lines.append("- Session: \(sessionText(session))")
        }
        lines.append("")

        for turn in record.turns {
            let who: String
            switch turn.role {
            case .user: who = "**You**"
            case .assistant: who = "**RTI**"
            case .system: who = "**System**"
            case .tool: who = "**Tool**"
            case .unknown: who = "**Unknown**"
            }
            let stamp = turn.createdAt.map { " _(\(SessionsWindowRules.timeText($0)))_" } ?? ""
            lines.append(who + stamp)
            lines.append("")
            lines.append(turn.text)
            lines.append("")
            for attachment in turn.attachments {
                lines.append("- Source: \(attachment.name) — \(sourceLine(attachment))")
            }
            if !turn.attachments.isEmpty { lines.append("") }
            if let error = turn.error, !error.isEmpty {
                lines.append("_Failed: \(error)_")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func sourceLine(_ attachment: AttachmentRecord) -> String {
        var parts = [kindLabel(attachment.kind)]
        if let bytes = attachment.byteCount { parts.append(ChatLibraryFormat.bytes(bytes)) }
        if let pages = attachment.pageCount { parts.append("\(pages) pages") }
        if let hash = attachment.contentHash { parts.append("sha256 \(ChatLibraryFormat.shortHash(hash))") }
        if let truncation = attachment.truncation { parts.append(truncation.summary) }
        return parts.joined(separator: " · ")
    }

    static func sessionText(_ link: SessionLink) -> String {
        [link.label, link.kind, link.id].compactMap { $0 }.joined(separator: " · ")
    }

    static func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// "PDF", "Screenshot", "Link"… for a source row.
    static func kindLabel(_ kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .word: "Word"
        case .powerpoint: "PowerPoint"
        case .excel: "Excel"
        case .html: "HTML"
        case .text: "Text"
        case .markdown: "Markdown"
        case .code: "Code"
        case .image: "Image"
        case .screenshot: "Screenshot"
        case .link: "Link"
        case .selection: "Selection"
        case .other: "File"
        }
    }
}

/// Small formatting rules the library shares.
enum ChatLibraryFormat {
    /// "1.2 MB", "345 KB", "912 bytes".
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "12 chats · 4.2 MB saved". Nil until the store has answered, so the
    /// line is never a zero standing in for an unknown.
    static func storageLine(chats: Int, legacyLogs: Int, bytes: Int?) -> String? {
        guard let bytes else { return nil }
        var parts = ["\(chats) saved chat\(chats == 1 ? "" : "s")"]
        if legacyLogs > 0 { parts.append("\(legacyLogs) dated log\(legacyLogs == 1 ? "" : "s")") }
        parts.append("\(Self.bytes(bytes)) of saved copies")
        return parts.joined(separator: " · ")
    }

    /// The same facts in the fewest words, for the footer beside four buttons
    /// and the primary action. Nil until the store has answered.
    static func compactStorageLine(chats: Int, legacyLogs: Int, bytes: Int?) -> String? {
        guard let bytes else { return nil }
        var parts = [chatCount(chats)]
        if legacyLogs > 0 { parts.append(logCount(legacyLogs)) }
        parts.append(Self.bytes(bytes))
        return parts.joined(separator: " · ")
    }

    /// The footer line without the size: what fits at the window's minimum
    /// width, so the size is dropped whole rather than clipped.
    static func countsLine(chats: Int, legacyLogs: Int) -> String {
        var parts = [chatCount(chats)]
        if legacyLogs > 0 { parts.append(logCount(legacyLogs)) }
        return parts.joined(separator: " · ")
    }

    /// "4 chats": the last thing the footer keeps.
    static func chatCount(_ chats: Int) -> String {
        "\(chats) chat\(chats == 1 ? "" : "s")"
    }

    static func logCount(_ logs: Int) -> String {
        "\(logs) log\(logs == 1 ? "" : "s")"
    }

    /// The first eight hex characters of a hash, for a row that shows one.
    static func shortHash(_ hash: String) -> String {
        hash.count <= 8 ? hash : String(hash.prefix(8)) + "…"
    }
}

// MARK: - Resume

/// The one boundary between the Chats library and RTI's live chat: a
/// notification, so the library never reaches into the composer.
enum ChatLibraryResume {
    /// Continue a saved chat in RTI's live chat surface. The id is the whole
    /// contract: the handler loads that thread, or reports that it is gone.
    static func resume(id: String) {
        NotificationCenter.default.post(name: .rtiResumeChat, object: id)
    }

    /// Reuse a dated legacy log in a new chat.
    ///
    /// The seed is the payload: the handler attaches `seed.sourceText` as
    /// source material, puts `seed.prompt` in the composer as an editable
    /// draft, and sends nothing. A dated log has no chat boundaries to reopen,
    /// so nothing is joined and no chat id is named.
    static func seedDatedChat(_ seed: ChatLibraryDatedSeed) {
        NotificationCenter.default.post(name: ChatLibraryDatedSeed.notificationName, object: seed)
    }
}
