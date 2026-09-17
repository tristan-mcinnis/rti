import Foundation

/// Appends a line-per-turn JSONL log of every assistant turn into the vault, so
/// past chats — and the prompts/modes that produced them — stay reviewable
/// later and are reachable by Ava's vault search. Text only: no database, no
/// in-app reader. Query with `jq`/DuckDB/Neon on demand.
///
/// Location: `<vault>/databases/projects/personal/rti/turns/<yyyy-MM-dd>.jsonl`,
/// derived from RTI's configured `recordings_dir` so the vault path is never
/// hardcoded here. Per-day files keep any single iCloud/git-synced file small.
enum VaultLogStore {
    struct TurnRecord: Codable {
        struct Latency: Codable {
            let totalMs: Int
            let firstTokenMs: Int?
            let toolMs: Int
            let toolCount: Int
        }

        let ts: String            // ISO-8601, stamped when the turn was sent
        let action: String        // "Ask" | "Assist" | "Recap" | …
        let mode: String?         // active prompt mode, if any
        // `provider`/`model`/`smart` stay the EFFECTIVE values: the model that
        // actually ran. The added fields are the chosen side plus the facts a
        // later audit needs. Keys are only added, never removed, so older days
        // still decode.
        let provider: String
        let model: String
        let smart: Bool
        let selectedProvider: String?
        let selectedModel: String?
        let reasoning: String?
        let thinkingSent: Bool?
        let imageRoute: String?
        let imageCount: Int?
        let toolPolicy: String?
        let inSession: Bool       // was a live session running
        let contextUsed: Bool     // transcript attached
        let screenUsed: Bool      // OCR screen attached
        let userInput: String
        let transcriptContext: String
        let output: String
        let latency: Latency?
        let sources: [String]
        /// One entry per tool the assistant actually called, in call order.
        let toolCalls: [ToolCall]?
        /// The chat thread this turn belongs to, and the turn's own id. These
        /// are the precise links between the daily log and the structured
        /// thread, and the only rows a thread deletion may remove.
        let threadID: String?
        let turnID: String?

        /// The evidence behind a tool line: what was asked, what came back,
        /// how long it took. App-side, in RTI's own legacy turn log; the
        /// structured thread stores the shared schema's `ToolCall` instead.
        struct ToolCall: Codable {
            let name: String
            let arguments: String
            let status: String
            let elapsedMS: Int
            let resultCharacters: Int
        }
    }

    /// A report on removing one thread's owned compatibility projections.
    /// Failures are reported, never swallowed: a projection that could not be
    /// cleaned is named so the caller can say so instead of pretending the
    /// delete was complete.
    struct ProjectionCleanup: Sendable, Equatable {
        var removedJSONLRows: Int = 0
        var removedMarkdownBlocks: Int = 0
        var failures: [String] = []

        var isClean: Bool { failures.isEmpty }
        var removedAnything: Bool { removedJSONLRows > 0 || removedMarkdownBlocks > 0 }
    }

    /// Remove the daily-log rows that belong to one chat thread, by exact ID.
    /// Rows that do not parse, or that carry no thread id, are kept: an
    /// unknown row is never assumed to belong to the thread being deleted.
    /// Returns how many rows went.
    @discardableResult
    static func removeTurns(threadID: String) -> Int {
        removeOwnedProjections(threadID: threadID).removedJSONLRows
    }

    /// Remove EVERY compatibility projection this store wrote for one chat
    /// thread: its rows in the daily JSONL and its blocks in the daily
    /// Markdown chat log. Both are linked by the thread's own id, so an
    /// unlinked legacy row is never touched and no original source, meeting,
    /// or recording is removed here.
    @discardableResult
    static func removeOwnedProjections(threadID: String) -> ProjectionCleanup {
        var report = ProjectionCleanup()
        guard !threadID.isEmpty, let rtiDir = rtiDirectory() else { return report }
        let turnsDir = rtiDir.appendingPathComponent("turns", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: turnsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jsonl" {
                do {
                    report.removedJSONLRows += try removeJSONLRows(threadID: threadID, from: file)
                } catch {
                    report.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        let chatDir = rtiDir.appendingPathComponent("chats", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: chatDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" {
                do {
                    report.removedMarkdownBlocks += try removeMarkdownBlocks(threadID: threadID, from: file)
                } catch {
                    report.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    private static func removeJSONLRows(threadID: String, from file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = removingJSONLRows(threadID: threadID, from: text)
        guard result.removed > 0 else { return 0 }
        try result.text.write(to: file, atomically: true, encoding: .utf8)
        return result.removed
    }

    /// Pure: drop the JSONL rows whose record carries this exact thread id.
    /// A row that does not decode, or carries no thread id, is kept: an
    /// unknown row is never assumed to belong to the thread being deleted.
    static func removingJSONLRows(threadID: String, from text: String) -> (text: String, removed: Int) {
        var kept: [String] = []
        var removed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(line)
            if let data = row.data(using: .utf8),
               let record = try? JSONDecoder().decode(TurnRecord.self, from: data),
               record.threadID == threadID
            {
                removed += 1
                continue
            }
            kept.append(row)
        }
        return (kept.joined(separator: "\n"), removed)
    }

    /// A Markdown chat block is wrapped in paired start/end markers carrying
    /// the thread's own id, so the block can be removed by id without being
    /// confused by a `##` heading inside the answer. A block with neither
    /// marker is legacy and is never guessed at.
    private static func markdownStartMarker(threadID: String) -> String {
        "<!-- rti-thread-start: \(threadID) -->"
    }

    private static func markdownEndMarker(threadID: String) -> String {
        "<!-- rti-thread-end: \(threadID) -->"
    }

    private static func removeMarkdownBlocks(threadID: String, from file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = removingMarkdownBlocks(threadID: threadID, from: text)
        guard result.removed > 0 else { return 0 }
        try result.text.write(to: file, atomically: true, encoding: .utf8)
        return result.removed
    }

    /// Pure: drop each `start → end` block that carries this exact thread id,
    /// including any `##` heading inside the answer. An unmatched marker or a
    /// legacy block with no markers is left untouched.
    static func removingMarkdownBlocks(threadID: String, from text: String) -> (text: String, removed: Int) {
        let start = markdownStartMarker(threadID: threadID)
        let end = markdownEndMarker(threadID: threadID)
        let lines = text.components(separatedBy: "\n")
        var remove = Set<Int>()
        var openStart: Int?
        var blocks = 0
        for (index, line) in lines.enumerated() {
            if line.contains(start) {
                // A start before the previous end is malformed; reopen at the
                // newest so a broken pair is never half-deleted.
                openStart = index
            } else if line.contains(end), let startIndex = openStart {
                for i in startIndex...index { remove.insert(i) }
                blocks += 1
                openStart = nil
            }
        }
        // A start with no matching end is left exactly where it is: an
        // unmatched marker is not proof of ownership of anything.
        guard blocks > 0 else { return (text, 0) }
        let kept = lines.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
        return (kept.joined(separator: "\n"), blocks)
    }

    /// Append one completed turn. Best-effort, off the main thread; silently
    /// no-ops if the vault can't be located.
    static func append(_ record: TurnRecord) {
        DispatchQueue.global(qos: .utility).async {
            guard let rtiDir = rtiDirectory() else { return }
            let turnsDir = rtiDir.appendingPathComponent("turns", isDirectory: true)
            try? FileManager.default.createDirectory(at: turnsDir, withIntermediateDirectories: true)
            writeReadmeIfMissing(in: rtiDir)

            guard let line = encode(record) else { return }
            let file = turnsDir.appendingPathComponent("\(dayStamp.string(from: Date())).jsonl")
            appendLine(line, to: file)
            appendMarkdownChat(record, in: rtiDir)
        }
    }

    // MARK: - Paths

    /// `<vault>/databases/projects/personal/rti`, derived from RTI's config.
    /// Also used by SessionArchive to place per-session records in the vault.
    static func rtiDirectory() -> URL? {
        VaultPaths.rtiDirectory()
    }

    /// The vault's meeting recordings directory. RTI uses this only to derive
    /// adjacent vault paths for its text handoff; it never writes audio here.
    static func recordingsDirectory() -> URL? {
        VaultPaths.preferredDatabasesDirectory()?
            .appendingPathComponent("meetings/recordings", isDirectory: true)
    }

    // MARK: - Writing

    private static func encode(_ record: TurnRecord) -> String? {
        guard let data = try? jsonEncoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func appendLine(_ line: String, to file: URL) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// Human-readable chat log for the overlay as a quick vault-RAG surface.
    /// JSONL remains the machine log; this is the skim/review copy.
    private static func appendMarkdownChat(_ record: TurnRecord, in rtiDir: URL) {
        let chatDir = rtiDir.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let file = chatDir.appendingPathComponent("\(dayStamp.string(from: Date())).md")
        if !FileManager.default.fileExists(atPath: file.path) {
            let title = "# RTI vault chat — \(dayStamp.string(from: Date()))\n\n"
            try? title.write(to: file, atomically: true, encoding: .utf8)
        }
        var tags: [String] = [record.action]
        if let mode = record.mode, !mode.isEmpty { tags.append(mode) }
        if record.inSession { tags.append("live session") } else { tags.append("standalone") }
        if record.contextUsed { tags.append("transcript") }
        if record.screenUsed { tags.append("screen") }
        let start = record.threadID.map { "<!-- rti-thread-start: \($0) -->\n\n" } ?? ""
        let end = record.threadID.map { "\n\n<!-- rti-thread-end: \($0) -->" } ?? ""
        let block = """

        \(start)## \(record.ts)

        _\(tags.joined(separator: " · "))_

        **You**

        \(record.userInput)

        **RTI**

        \(record.output)\(end)

        """
        appendLine(block, to: file)
    }

    /// Make the resource self-documenting so anyone (or any agent) browsing the
    /// vault knows what these files are and where they came from.
    private static func writeReadmeIfMissing(in rtiDir: URL) {
        let readme = rtiDir.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        try? readmeBody.write(to: readme, atomically: true, encoding: .utf8)
    }

    private static let readmeBody = """
    ---
    title: "RTI session logs"
    type: reference
    ---

    # RTI session logs

    Written by **RTI** (the real-time meeting copilot on the Mac). One JSONL line
    per assistant turn under `turns/<yyyy-MM-dd>.jsonl`, plus a readable Markdown
    chat log under `chats/<yyyy-MM-dd>.md`.

    Each line: `{ts, action, mode, provider, model, smart, inSession,
    contextUsed, screenUsed, userInput, transcriptContext, output, latency,
    sources}`.

    Purpose: review past chats, especially vault-RAG questions, and study how
    prompts/modes affect the assistant's output. Text only — query with `jq` /
    DuckDB / Neon on demand.
    Not a corpus and not searched in-app.
    """

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
