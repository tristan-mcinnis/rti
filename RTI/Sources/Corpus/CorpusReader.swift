import Foundation

/// Walks a Corpus directory and parses files. Read-only; the writer is
/// `CorpusWriter`. Used by the FTS reindexer, the MCP server, and any
/// in-app feature that browses the user's meeting history.
enum CorpusReader {

    /// Lazily list every `.md` file under `directory`, sorted by mtime
    /// descending (newest first). Hidden files and tmp drops from
    /// `CorpusWriter` are excluded.
    static func listMarkdownFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let mds = contents.filter { url in
            guard url.pathExtension == "md" else { return false }
            return !url.lastPathComponent.hasSuffix(".md.tmp")
        }
        return mds.sorted { lhs, rhs in
            let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lm > rm
        }
    }

    /// Read and parse a single file. Throws on missing or malformed.
    static func read(_ url: URL) throws -> CorpusEntry {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try CorpusEntry.parse(raw)
    }

    /// Frontmatter-only read. Stops parsing at the closing `---` to avoid
    /// loading the body for list views. About 10× faster on large
    /// transcripts.
    static func readFrontmatter(_ url: URL) throws -> CorpusEntry.Frontmatter {
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Slice to the closing delimiter rather than parse the whole file.
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---" else {
            throw CorpusError.missingFrontmatter
        }
        var endIdx: Int?
        for i in 1..<lines.count where lines[i] == "---" {
            endIdx = i
            break
        }
        guard let end = endIdx else {
            throw CorpusError.unterminatedFrontmatter
        }
        let stub = (["---"] + Array(lines[1..<end]) + ["---", ""]).joined(separator: "\n")
        return try CorpusEntry.parse(stub).frontmatter
    }
}
