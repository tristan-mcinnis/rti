import Foundation
import RTICore

/// RTI's legacy daily turn logs, read honestly.
///
/// Before RTI kept structured threads, every assistant turn was appended to
/// `<vault>/databases/projects/personal/rti/turns/<yyyy-MM-dd>.jsonl`
/// (`VaultLogStore`). Those files are a day's worth of turns, not a
/// conversation: nothing in them says where one chat ended and the next
/// began. So the library shows them as what they are — dated entries, each
/// with its own timestamp — and never assembles them into a chat.
///
/// A newer row carries `threadID`: it is the daily-log projection of a saved
/// thread, which the Chats list already shows. Those rows are counted and left
/// out here, so one history is never listed twice. Rows without a thread id
/// are truly legacy and are shown exactly as recorded.
///
/// Read only. Nothing here writes, renames, truncates, or imports a log, and
/// nothing here opens `chats/<yyyy-MM-dd>.md`, which is the same turns in a
/// skim form (`VaultLogStore` writes both from one record).
actor ChatLibraryLegacyReader {
    /// `<vault>/databases/projects/personal/rti/turns`. Injected.
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Every day log, newest day first. An unreadable file is reported as a
    /// log with a state, never skipped and never replaced.
    func logs() -> [ChatLibraryLegacy.Log] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else {
            return [ChatLibraryLegacy.Log.unreadable(day: root.lastPathComponent, reason: "The dated logs folder could not be listed.")]
        }
        return names
            .filter { $0.hasSuffix(".jsonl") }
            .sorted(by: >)
            .map { name in read(day: String(name.dropLast(".jsonl".count)), file: root.appendingPathComponent(name)) }
    }

    /// Read one day's file. A line that does not decode is counted and left
    /// out; the rest of the day still reads. A row that belongs to a saved
    /// chat is counted and left out of the entries, so the day shows only what
    /// no saved chat owns.
    private func read(day: String, file: URL) -> ChatLibraryLegacy.Log {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .unreadable(day: day, path: file.path, reason: "This log could not be read.")
        }
        var turns: [ChatLibraryLegacy.Turn] = []
        var projected = 0
        var skipped = 0
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let record = try? JSONDecoder().decode(ChatLibraryLegacy.Turn.self, from: data),
                  record.isReadable
            else {
                skipped += 1
                continue
            }
            let turn = record.with(id: lineNumber)
            guard !turn.isProjectionOfSavedChat else {
                projected += 1
                continue
            }
            turns.append(turn)
        }
        return ChatLibraryLegacy.Log(
            day: day,
            sourcePath: file.path,
            turns: turns,
            projectedTurnCount: projected,
            skippedLines: skipped,
            state: .read(skippedLines: skipped)
        )
    }
}

/// One legacy day log, and the turns inside it.
struct ChatLibraryLegacy {
    enum State: Equatable, Sendable {
        /// Read. `skippedLines` counts the lines that did not decode.
        case read(skippedLines: Int)
        /// The file could not be read at all; the reason is shown as written.
        case unreadable(String)
    }

    /// One stored line of a day log: one dated turn, exactly as recorded.
    ///
    /// The fields are the ones a reader needs. `transcriptContext` is
    /// deliberately not kept: a live transcript attached to a turn can be
    /// large, and the library never shows it.
    struct Turn: Decodable, Equatable, Sendable, Identifiable {
        /// The line number in the day's file, stable within that file. Not a
        /// stored field, so decoding leaves it at zero until `with(id:)`.
        private(set) var id: Int = 0
        let ts: String?
        let action: String?
        let mode: String?
        let inSession: Bool?
        let userInput: String?
        let output: String?
        let sources: [String]?
        let toolCalls: [ToolCall]?
        /// The saved chat thread this row belongs to, when a newer build wrote
        /// it from a structured turn. Such a row is a projection of a chat the
        /// Chats list already shows.
        let threadID: String?

        struct ToolCall: Decodable, Equatable, Sendable {
            let name: String?
        }

        /// The stored keys this reader keeps. A line written by a newer build
        /// carries more; the rest is left on disk.
        private enum CodingKeys: String, CodingKey {
            case ts, action, mode, inSession, userInput, output, sources, toolCalls, threadID
        }

        /// True when the row belongs to a saved chat and therefore belongs in
        /// the Chats list, not in the dated log.
        var isProjectionOfSavedChat: Bool {
            !(threadID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var isReadable: Bool {
            !(userInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func with(id: Int) -> Turn {
            var copy = self
            copy.id = id
            return copy
        }

        /// "15:04" in this Mac's zone, or the raw stamp when it does not parse.
        var timeText: String {
            guard let ts else { return "" }
            guard let date = try? Date(ts, strategy: .iso8601) else { return ts }
            return SessionsWindowRules.timeText(date)
        }

        /// What the turn was asked as: the canned action, the slash command,
        /// or the typed question.
        var question: String { userInput ?? "" }

        var answer: String { output ?? "" }

        var toolNames: [String] {
            (toolCalls ?? []).compactMap(\.name)
        }

        /// "Ask · screen · 2 tools · northwind-brief.md", for the entry's line.
        var detailText: String {
            var parts: [String] = []
            if let action, !action.isEmpty { parts.append(action) }
            if let mode, !mode.isEmpty { parts.append(mode) }
            if inSession == true { parts.append("Live session") }
            if !toolNames.isEmpty { parts.append("\(toolNames.count) tool\(toolNames.count == 1 ? "" : "s")") }
            if let sources, !sources.isEmpty { parts.append("\(sources.count) source\(sources.count == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
    }

    /// One day of the legacy log.
    struct Log: Identifiable, Equatable, Sendable {
        /// The day, as the file names it: "2026-09-12".
        let day: String
        /// The log file this day came from, as metadata. Nothing here reads it
        /// back; a seed carries it as a reference.
        let sourcePath: String?
        /// The dated entries no saved chat owns, in recorded order.
        let turns: [Turn]
        /// Rows of this day that belong to saved chats. Counted, never shown:
        /// they are listed under Chats.
        let projectedTurnCount: Int
        let skippedLines: Int
        let state: State

        var id: String { day }

        static func unreadable(day: String, path: String? = nil, reason: String) -> Log {
            Log(day: day, sourcePath: path, turns: [], projectedTurnCount: 0, skippedLines: 0, state: .unreadable(reason))
        }

        var turnCount: Int { turns.count }

        /// True when every readable row in this day belongs to a saved chat:
        /// the day has nothing of its own to show.
        var isEntirelyProjected: Bool { turns.isEmpty && projectedTurnCount > 0 }

        /// "12 Sep 2026 · 14 turns". The date is the file's day, parsed
        /// without a time zone of its own.
        var title: String {
            guard let date = Self.date(fromDay: day) else { return day }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: date)
        }

        var detailText: String {
            switch state {
            case .read(let skipped):
                var parts = ["\(turnCount) turn\(turnCount == 1 ? "" : "s")"]
                if projectedTurnCount > 0 { parts.append("\(projectedTurnCount) in chats") }
                if skipped > 0 { parts.append("\(skipped) line\(skipped == 1 ? "" : "s") skipped") }
                return parts.joined(separator: " · ")
            case .unreadable(let reason):
                return reason
            }
        }

        /// Where the rows this day does not show went. Nil when none were
        /// left out.
        var projectionNote: String? {
            guard projectedTurnCount > 0 else { return nil }
            let rows = "\(projectedTurnCount) row\(projectedTurnCount == 1 ? "" : "s")"
            let verb = projectedTurnCount == 1 ? "belongs" : "belong"
            return "\(rows) from this day \(verb) to saved chats. They are listed under Chats, not repeated here."
        }

        /// The honest line about what this is, shown above the entries.
        var orientationText: String {
            "A dated log, not a saved chat. Each entry below is one turn as it was recorded; nothing says where one chat ended and the next began."
        }

        static func date(fromDay day: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: day)
        }
    }
}

/// A dated legacy log, or one entry inside it, as RTI's chat receives it.
///
/// A typed, immutable seed, so "use this in a new chat" reuses the recorded
/// entries themselves instead of joining a day into a conversation that never
/// existed. The seed carries:
///
/// - the day, and for one entry its line in the log;
/// - each entry's own timestamp, question, answer and mentioned sources,
///   exactly as recorded and in recorded order;
/// - the log file as a path reference (metadata only: nothing here reads it);
/// - the text a composer attaches, and a draft prompt.
///
/// It carries no `transcriptContext`, merges nothing, and claims no original
/// file: a legacy row has none, and the seed says so by carrying no original
/// path. Nothing is sent by seeding: the handler attaches `sourceText`, leaves
/// `prompt` editable, and waits for the user.
struct ChatLibraryDatedSeed: Equatable, Sendable {
    /// The notification the library posts, with the seed as its object.
    ///
    /// Spelled on the seed rather than as a `Notification.Name` extension
    /// member, so it can never collide with a central name: the handler
    /// observes `Notification.Name("rtiSeedDatedChat")` or this constant.
    static let notificationName = Notification.Name("rtiSeedDatedChat")

    /// How much of the log is being reused.
    enum Scope: String, Sendable, Equatable {
        /// Every displayed entry in the day.
        case day
        /// One dated entry, from one line of the log.
        case entry
    }

    /// One dated turn, as recorded.
    struct Entry: Equatable, Sendable {
        /// The line of the day's file this entry came from.
        let line: Int
        let day: String
        /// The raw ISO stamp, when the row had one.
        let stamp: String?
        /// "07:04" in this Mac's zone, or the raw stamp when it does not parse.
        let timeText: String
        let action: String?
        let mode: String?
        let inSession: Bool
        let question: String
        let answer: String
        /// Files the turn mentioned. A reference the log recorded, not an
        /// original this library holds.
        let sources: [String]
        /// The tools the turn called, in call order.
        let tools: [String]
    }

    /// "legacy-day-2026-09-12" or "legacy-entry-2026-09-12-2".
    let id: String
    let day: String
    let scope: Scope
    /// "12 Sep 2026", or "12 Sep 2026 · 07:04" for one entry.
    let title: String
    /// The log file this came from, kept as a reference and never read.
    let sourcePath: String?
    let entries: [Entry]
    /// The entries as the text an editor attaches, each keeping its own
    /// timestamp, in recorded order, with nothing summarised or merged.
    let sourceText: String
    /// The draft the composer starts with. Editable, and never sent by itself.
    let prompt: String

    /// True when this seed carries something to reuse.
    var isEmpty: Bool { entries.isEmpty }
}

extension ChatLibraryDatedSeed {
    /// The whole displayed day. Nil when the day has nothing a chat could
    /// reuse, which is the honest answer for an empty or unreadable log.
    static func day(_ log: ChatLibraryLegacy.Log) -> ChatLibraryDatedSeed? {
        guard !log.turns.isEmpty else { return nil }
        let entries = log.turns.map { Entry(turn: $0, day: log.day) }
        let count = entries.count
        return ChatLibraryDatedSeed(
            id: "legacy-day-\(log.day)",
            day: log.day,
            scope: .day,
            title: log.title,
            sourcePath: log.sourcePath,
            entries: entries,
            sourceText: sourceText(
                entries: entries,
                heading: "Dated log, \(log.title)",
                orientation: log.orientationText
            ),
            prompt: "About this dated log (\(log.title), \(count) entr\(count == 1 ? "y" : "ies")): "
        )
    }

    /// One dated entry. Nil for a row that belongs to a saved chat or has no
    /// turn in it, so a projection is never reused as if it were legacy.
    static func entry(_ turn: ChatLibraryLegacy.Turn, in log: ChatLibraryLegacy.Log) -> ChatLibraryDatedSeed? {
        guard log.turns.contains(where: { $0.id == turn.id }), turn.isReadable else { return nil }
        let entry = Entry(turn: turn, day: log.day)
        let time = entry.timeText.isEmpty ? log.title : "\(log.title) · \(entry.timeText)"
        return ChatLibraryDatedSeed(
            id: "legacy-entry-\(log.day)-\(turn.id)",
            day: log.day,
            scope: .entry,
            title: time,
            sourcePath: log.sourcePath,
            entries: [entry],
            sourceText: sourceText(
                entries: [entry],
                heading: "Dated entry, \(time)",
                orientation: log.orientationText
            ),
            prompt: "About this dated entry (\(time)): "
        )
    }

    /// The dated entries as source material. Each keeps its own timestamp and
    /// its recorded order; the header says plainly that these are dated
    /// records, not one conversation.
    static func sourceText(
        entries: [Entry],
        heading: String,
        orientation: String
    ) -> String {
        var lines = ["## \(heading)", "", orientation, ""]
        for entry in entries {
            var stamp = entry.timeText.isEmpty ? "entry \(entry.line)" : entry.timeText
            if let action = entry.action, !action.isEmpty { stamp += " · \(action)" }
            if let mode = entry.mode, !mode.isEmpty { stamp += " · \(mode)" }
            if entry.inSession { stamp += " · live session" }
            lines.append("### \(stamp)")
            lines.append("")
            if !entry.question.isEmpty {
                lines.append("**Asked:** \(entry.question)")
                lines.append("")
            }
            if !entry.answer.isEmpty {
                lines.append("**Answered:** \(entry.answer)")
                lines.append("")
            }
            if !entry.sources.isEmpty {
                lines.append("Mentioned sources: \(entry.sources.joined(separator: ", "))")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatLibraryDatedSeed.Entry {
    init(turn: ChatLibraryLegacy.Turn, day: String) {
        self.init(
            line: turn.id,
            day: day,
            stamp: turn.ts,
            timeText: turn.timeText,
            action: turn.action,
            mode: turn.mode,
            inSession: turn.inSession ?? false,
            question: turn.question,
            answer: turn.answer,
            sources: turn.sources ?? [],
            tools: turn.toolNames
        )
    }
}
