import Foundation

/// Neon-backed vault search: shells out to the vault-search CLI's `search`
/// subcommand, which runs the same hybrid (BM25 + pgvector RRF) engine the
/// rest of the vault uses — the "one brain". Semantic, so it finds the right
/// document even without exact keyword overlap, and it reuses the maintained
/// index instead of RTI re-scanning files.
///
/// Every search answers with an ``Outcome``: rows, an honest no-match, or the
/// reason the index could not answer. A failure is never collapsed into "no
/// results" — the caller reports degraded retrieval instead of letting a dead
/// index read as an empty vault (see `VaultRetrieval.Status`).
enum VaultSearchCLI {
    /// What one hybrid search came back with.
    enum Outcome: Equatable {
        /// The index answered with these rows.
        case results([VaultSearch.Result])
        /// The index answered and has nothing for the query.
        case noMatch
        /// The index could not answer. The reason is one short diagnostic line,
        /// fit for a log line or a retrieval trace.
        case unavailable(reason: String)
    }

    /// The vault-search CLI, relative to the vault git root. `code/hermes` was
    /// the previous owner; the CLI lives at `code/vault-search` now and the old
    /// path is gone, so this is the only live resolution.
    static let cliRelativePath = "code/vault-search/src/cli.ts"

    /// How long to wait for the CLI before giving up and letting the caller
    /// fall back. The warm query is ~2s; this leaves headroom for a cold start.
    private static let timeout: TimeInterval = 12

    /// Fire-and-forget: wake the Neon compute (it suspends when idle, costing
    /// the next real search a ~10-15s serverless cold-start). Uses a cheap
    /// fts query — no Jina embed — purely to keep the database warm. Output is
    /// discarded; never blocks the caller. Safe to call repeatedly.
    static func warmUp() {
        guard let bun = ExternalTools.bun(), let cli = cliPath() else { return }
        let packageDir = cli.deletingLastPathComponent().deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = bun
            proc.currentDirectoryURL = packageDir
            proc.arguments = ["run", cli.path, "search", "warmup", "--mode", "fts", "--limit", "1"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
        }
    }

    /// One search. `project` is a project slug the CLI filters by server-side
    /// (`--project`); nil searches the whole vault.
    static func searchOutcome(query: String, limit: Int = 6, project: String? = nil) async -> Outcome {
        guard let bun = ExternalTools.bun() else {
            return .unavailable(reason: "bun is not on PATH")
        }
        guard let cli = cliPath() else {
            return .unavailable(reason: "the vault-search CLI is missing at <vault>/\(cliRelativePath)")
        }
        let packageDir = cli.deletingLastPathComponent().deletingLastPathComponent()
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(
                    bun: bun, cli: cli, packageDir: packageDir,
                    query: query, limit: limit, project: project
                ))
            }
        }
    }

    /// The row-or-nil shape older callers use: rows when the index answered
    /// (an empty array is a legitimate no-match), nil when it could not answer
    /// at all. Callers that need the reason use ``searchOutcome(query:limit:project:)``.
    static func search(query: String, limit: Int = 6) async -> [VaultSearch.Result]? {
        switch await searchOutcome(query: query, limit: limit) {
        case .results(let rows): rows
        case .noMatch: []
        case .unavailable: nil
        }
    }

    // MARK: - Process

    private static func run(
        bun: URL,
        cli: URL,
        packageDir: URL,
        query: String,
        limit: Int,
        project: String?
    ) -> Outcome {
        var arguments = ["run", cli.path, "search", query, "--limit", String(limit)]
        if let project, !project.isEmpty { arguments += ["--project", project] }

        let proc = Process()
        proc.executableURL = bun
        proc.currentDirectoryURL = packageDir
        proc.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do { try proc.run() } catch {
            return .unavailable(reason: "could not start the vault-search CLI: \(error.localizedDescription)")
        }

        // Drain BOTH pipes on side threads: an unread stderr fills its buffer
        // and blocks the child, and the diagnostics live there.
        let group = DispatchGroup()
        var data = Data()
        var diagnostics = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return .unavailable(reason: "the vault-search CLI did not answer within \(Int(timeout))s")
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let detail = lastLine(diagnostics).map { ": \($0)" } ?? ""
            return .unavailable(reason: "the vault-search CLI exited \(proc.terminationStatus)\(detail)")
        }
        return parse(data)
    }

    // MARK: - Parse

    private struct CLIResponse: Decodable {
        let ok: Bool
        let results: [CLIRow]?
        /// The CLI reports its own failures (unreachable database, bad query)
        /// as `{"ok":false,"error":"…"}` with exit status 0, so the message has
        /// to be read rather than inferred.
        let error: String?
    }
    private struct CLIRow: Decodable {
        let title: String?
        let type: String?
        let project: String?
        let path: String?
        let date: String?
        let summary: String?
    }

    /// The CLI's one JSON line as an outcome. Unreadable JSON and a reported
    /// `ok:false` are both `unavailable` with the cause attached, never an
    /// empty result set.
    static func parse(_ data: Data) -> Outcome {
        guard let resp = try? JSONDecoder().decode(CLIResponse.self, from: data) else {
            return .unavailable(reason: "the vault-search CLI returned unreadable JSON")
        }
        guard resp.ok else {
            let detail = resp.error.flatMap { $0.isEmpty ? nil : $0 }
            return .unavailable(reason: "the vault-search CLI reported a failure" + (detail.map { ": \($0)" } ?? ""))
        }
        let rows = (resp.results ?? []).map { row in
            VaultSearch.Result(
                title: row.title ?? displayName(from: row.path),
                relativePath: tidyPath(row.path),
                modified: parseDay(row.date),
                excerpt: (row.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                score: 0
            )
        }
        return rows.isEmpty ? .noMatch : .results(rows)
    }

    // MARK: - Resolution

    private static func cliPath() -> URL? {
        VaultPaths.vaultToolURL(cliRelativePath)
    }

    // MARK: - Field helpers

    /// `kb/databases/projects/n/00-status.md` → `projects/n/00-status.md`, the
    /// `databases/`-relative style the local scan and the rest of RTI use.
    /// The old `vault/databases/` form is kept for rows indexed before the
    /// `kb/` move.
    private static func tidyPath(_ path: String?) -> String {
        guard let p = path else { return "" }
        for prefix in ["kb/databases/", "vault/databases/", "databases/"] where p.hasPrefix(prefix) {
            return String(p.dropFirst(prefix.count))
        }
        return p
    }

    private static func displayName(from path: String?) -> String {
        guard let p = path, let last = p.split(separator: "/").last else { return "Untitled" }
        return last.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: " ")
    }

    /// The last non-empty line of a child's stderr: the CLI's own final
    /// diagnostic, without the stack frames above it.
    private static func lastLine(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Parse the leading `yyyy-MM-dd` of an ISO date string; the formatter only
    /// prints the day, so we don't need the time.
    private static func parseDay(_ iso: String?) -> Date {
        guard let iso, iso.count >= 10 else { return .distantPast }
        return dayParser.date(from: String(iso.prefix(10))) ?? .distantPast
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
