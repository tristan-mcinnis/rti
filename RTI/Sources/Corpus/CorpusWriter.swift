import Foundation

/// Writes a `CorpusEntry` to a markdown file atomically. Path generation
/// (`YYYY-MM-DD-<slug>.md` with collision handling) is the writer's job;
/// callers supply the entry, a corpus directory, and a slug.
enum CorpusWriter {

    /// Atomic file write: render to a `.tmp` sibling then rename. Survives
    /// a crash mid-write — readers either see the previous file or the
    /// fully-rendered new one, never a partial.
    /// - Parameters:
    ///   - entry: the corpus entry to render.
    ///   - directory: the corpus root (typically `~/meetings/`).
    ///   - slug: a kebab-case slug derived from the title; the writer adds
    ///     `-1`, `-2`, etc. on collision.
    /// - Returns: the URL the file was actually written to.
    @discardableResult
    static func write(
        _ entry: CorpusEntry,
        to directory: URL,
        slug: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let datePart = isoDate(entry.frontmatter.date)
        let safeSlug = sanitiseSlug(slug)
        let url = uniqueURL(in: directory, datePart: datePart, slug: safeSlug, fileManager: fileManager)
        let body = try entry.render()
        let tmp = url.deletingPathExtension().appendingPathExtension("md.tmp")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        // FileManager.replaceItemAt handles the rename + cleanup of the
        // tmp on success. If the destination doesn't exist, fall back to a
        // simple move.
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: url)
        }
        return url
    }

    /// Build a kebab-case slug capped at 40 chars from a free-text title.
    /// Falls back to `meeting-HHMM` when the title is empty or yields an
    /// empty slug after sanitisation.
    static func slug(forTitle title: String?, date: Date = Date()) -> String {
        if let title, let slug = sanitiseSlugOptional(title) {
            return slug
        }
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        return "meeting-\(f.string(from: date))"
    }

    // MARK: - private

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private static func sanitiseSlug(_ raw: String) -> String {
        sanitiseSlugOptional(raw) ?? "meeting"
    }

    private static func sanitiseSlugOptional(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(40))
    }

    private static func uniqueURL(
        in directory: URL,
        datePart: String,
        slug: String,
        fileManager: FileManager
    ) -> URL {
        let base = "\(datePart)-\(slug)"
        var candidate = directory.appendingPathComponent("\(base).md")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }
}
