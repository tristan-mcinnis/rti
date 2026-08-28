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
        let provider: String
        let model: String
        let smart: Bool
        let inSession: Bool       // was a live session running
        let contextUsed: Bool     // transcript attached
        let screenUsed: Bool      // OCR screen attached
        let userInput: String
        let transcriptContext: String
        let output: String
        let latency: Latency?
        let sources: [String]
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
        let block = """

        ## \(record.ts)

        _\(tags.joined(separator: " · "))_

        **You**

        \(record.userInput)

        **RTI**

        \(record.output)

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
