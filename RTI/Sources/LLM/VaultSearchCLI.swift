import Foundation

/// Neon-backed vault search: shells out to the hermes CLI's `search`
/// subcommand, which runs the same hybrid (BM25 + pgvector RRF) engine the
/// rest of the vault uses — the "one brain". Semantic, so it finds the right
/// document even without exact keyword overlap, and it reuses the maintained
/// index instead of RTI re-scanning files.
///
/// Returns nil on ANY failure (bun missing, network down, db unreachable,
/// timeout, bad output) so the caller can fall back to the local grep scan —
/// RTI keeps working offline, just without semantic ranking.
enum VaultSearchCLI {
    /// How long to wait for the CLI before giving up and letting the caller
    /// fall back. The warm query is ~2s; this leaves headroom for a cold start.
    private static let timeout: TimeInterval = 12

    /// Fire-and-forget: wake the Neon compute (it suspends when idle, costing
    /// the next real search a ~10-15s serverless cold-start). Uses a cheap
    /// fts query — no Jina embed — purely to keep the database warm. Output is
    /// discarded; never blocks the caller. Safe to call repeatedly.
    static func warmUp() {
        guard let bun = bunPath(), let cli = cliPath() else { return }
        let hermesDir = cli.deletingLastPathComponent().deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = bun
            proc.currentDirectoryURL = hermesDir
            proc.arguments = ["run", cli.path, "search", "warmup", "--mode", "fts", "--limit", "1"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
        }
    }

    static func search(query: String, limit: Int = 6) async -> [VaultSearch.Result]? {
        guard let bun = bunPath(), let cli = cliPath() else { return nil }
        let hermesDir = cli.deletingLastPathComponent().deletingLastPathComponent() // src → hermes
        return await withCheckedContinuation { (cont: CheckedContinuation<[VaultSearch.Result]?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(bun: bun, cli: cli, cwd: hermesDir, query: query, limit: limit))
            }
        }
    }

    // MARK: - Process

    private static func run(bun: URL, cli: URL, cwd: URL, query: String, limit: Int) -> [VaultSearch.Result]? {
        let proc = Process()
        proc.executableURL = bun
        proc.currentDirectoryURL = cwd
        proc.arguments = ["run", cli.path, "search", query, "--limit", String(limit)]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe() // discard the CLI's diagnostics

        do { try proc.run() } catch { return nil }

        // Read on a side thread so a hung child can be killed on timeout.
        let group = DispatchGroup()
        group.enter()
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    // MARK: - Parse

    private struct CLIResponse: Decodable {
        let ok: Bool
        let results: [CLIRow]?
    }
    private struct CLIRow: Decodable {
        let title: String?
        let type: String?
        let project: String?
        let path: String?
        let date: String?
        let summary: String?
    }

    private static func parse(_ data: Data) -> [VaultSearch.Result]? {
        guard let resp = try? JSONDecoder().decode(CLIResponse.self, from: data), resp.ok else { return nil }
        let rows = resp.results ?? []
        return rows.map { row in
            VaultSearch.Result(
                title: row.title ?? displayName(from: row.path),
                relativePath: tidyPath(row.path),
                modified: parseDay(row.date),
                excerpt: (row.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                score: 0
            )
        }
    }

    // MARK: - Resolution

    private static func bunPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".bun/bin/bun"),
            URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            URL(fileURLWithPath: "/usr/local/bin/bun"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `<gitRoot>/code/hermes/src/cli.ts`, derived from the vault location the
    /// rest of RTI already resolves (databases is `<gitRoot>/vault/databases`).
    private static func cliPath() -> URL? {
        guard let databases = VaultWorkstreamStore.databasesDir() else { return nil }
        let gitRoot = databases.deletingLastPathComponent().deletingLastPathComponent() // databases → vault → gitRoot
        let cli = gitRoot.appendingPathComponent("code/hermes/src/cli.ts")
        return FileManager.default.fileExists(atPath: cli.path) ? cli : nil
    }

    // MARK: - Field helpers

    /// `vault/databases/projects/n/00-status.md` → `projects/n/00-status.md`,
    /// matching the grep path style; leaves other paths intact.
    private static func tidyPath(_ path: String?) -> String {
        guard let p = path else { return "" }
        for prefix in ["vault/databases/", "databases/"] where p.hasPrefix(prefix) {
            return String(p.dropFirst(prefix.count))
        }
        return p
    }

    private static func displayName(from path: String?) -> String {
        guard let p = path, let last = p.split(separator: "/").last else { return "Untitled" }
        return last.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: " ")
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
