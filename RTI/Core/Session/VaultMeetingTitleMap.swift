import Foundation

/// Which vault meeting note names which RTI session, by title.
///
/// The vault's meeting processor writes a note per recorded meeting whose
/// frontmatter says `source: rti-session-<yyyyMMdd-HHmmss>`. Its `title:` is a
/// good session title even when RTI's own summary call failed. This map reads
/// only the frontmatter (the first `headerLineLimit` lines, from a small
/// prefix of each file) and lives in memory only: it is a lookup, not an
/// index, and it is rebuilt on each Sessions list load, off the main thread.
public struct VaultMeetingTitleMap: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The note's `title:`.
        public let title: String
        /// The note's file name inside the meetings folder.
        public let fileName: String

        public init(title: String, fileName: String) {
            self.title = title
            self.fileName = fileName
        }
    }

    /// Only the first lines of a note are read for its frontmatter.
    public static let headerLineLimit = 40
    /// Bytes read from the head of each note (frontmatter is far smaller).
    public static let headerByteLimit = 8 * 1024

    /// Canonical session stamp (`yyyyMMdd-HHmmss`) → the note that names it.
    public private(set) var entries: [String: Entry]
    /// Note file name → the session stamp it names.
    public private(set) var stampsByFileName: [String: String]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
        self.stampsByFileName = Dictionary(
            entries.map { ($0.value.fileName, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public static let empty = VaultMeetingTitleMap()

    public var isEmpty: Bool { entries.isEmpty }

    /// The note title for a session stamp (`yyyyMMdd-HHmmss`).
    public func title(forStamp stamp: String) -> String? {
        entries[stamp]?.title
    }

    /// The session stamp a meeting note names, by its file name.
    public func stamp(forNoteFileName fileName: String) -> String? {
        stampsByFileName[fileName]
    }

    // MARK: - Build

    /// Read the frontmatter of every top-level `*.md` in `meetingsDirectory`.
    /// A missing folder gives an empty map. When two notes name the same
    /// session, the first by file name wins, so the result is stable.
    public static func build(meetingsDirectory: URL, fileManager: FileManager = .default) -> VaultMeetingTitleMap {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        var entries: [String: Entry] = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "md" {
            guard let head = readHead(of: url) else { continue }
            let front = parseFrontmatter(head)
            guard let stamp = front.sessionStamp, let title = front.title, entries[stamp] == nil else { continue }
            entries[stamp] = Entry(title: title, fileName: url.lastPathComponent)
        }
        return VaultMeetingTitleMap(entries: entries)
    }

    /// The `title:` and the RTI session stamp named by `source:` in a note's
    /// frontmatter. Handles a scalar (`source: rti-session-…`), an inline
    /// list (`source: [rti, rti-session-…]`), and a block list under
    /// `source:` or `sources:`. Only the first `headerLineLimit` lines count.
    public static func parseFrontmatter(_ text: String) -> (title: String?, sessionStamp: String?) {
        let lines = text.components(separatedBy: .newlines).prefix(headerLineLimit)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }

        var title: String?
        var stamp: String?
        var inSourceList = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if inSourceList, trimmed.hasPrefix("- ") {
                if stamp == nil { stamp = sessionStamp(in: String(trimmed.dropFirst(2))) }
                continue
            }
            inSourceList = false
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title":
                if title == nil { title = unquote(value) }
            case "source", "sources":
                if value.isEmpty {
                    inSourceList = true
                } else if stamp == nil {
                    stamp = sessionStamp(in: value)
                }
            default:
                break
            }
        }
        return (title.flatMap { $0.isEmpty ? nil : $0 }, stamp)
    }

    /// The first `rti-session-yyyyMMdd-HHmmss` stamp in `text`.
    public static func sessionStamp(in text: String) -> String? {
        guard let range = text.range(of: #"rti-session-\d{8}-\d{6}"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("rti-session-".count))
    }

    /// "2026-09-04 150016" (an archive folder) → "20260904-150016".
    public static func canonicalStamp(fromFolderName folder: String) -> String? {
        guard folder.range(of: #"^\d{4}-\d{2}-\d{2} \d{6}$"#, options: .regularExpression) != nil else { return nil }
        let digits = folder.filter(\.isNumber)
        return String(digits.prefix(8)) + "-" + String(digits.dropFirst(8))
    }

    // MARK: - Helpers

    private static func readHead(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerByteLimit), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
            if first == "\"" {
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else {
                value = value.replacingOccurrences(of: "''", with: "'")
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
