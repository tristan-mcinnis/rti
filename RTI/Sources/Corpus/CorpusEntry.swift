import Foundation
import Yams

/// One entry in the Corpus — the structured representation of a markdown
/// file under `~/meetings/`. Mirrors the YAML frontmatter schema documented
/// in `docs/specs/markdown-corpus-and-companions.md`. The body of the
/// markdown file (Summary + Transcript sections) lives separately on the
/// `body` field; encoding combines the two into a single file string.
///
/// Phase 3 (dual-write) keeps the structured `decisions` / `action_items`
/// fields off the frontmatter and surfaces them only in the body's Summary
/// section. Later phases can parse them out into structured arrays without
/// breaking existing files.
struct CorpusEntry: Equatable {
    /// Frontmatter — typed.
    struct Frontmatter: Codable, Equatable {
        var id: String
        var date: Date
        var capturedAt: Date?
        var duration: String?
        var title: String?
        var mode: String?
        var attendees: [String]?
        var speakerMap: [String: SpeakerMapEntry]?
        var keyTopics: [String]?
        var transcriptQuality: String?
        var wavPath: String?

        enum CodingKeys: String, CodingKey {
            case id
            case date
            case capturedAt = "captured_at"
            case duration
            case title
            case mode
            case attendees
            case speakerMap = "speaker_map"
            case keyTopics = "key_topics"
            case transcriptQuality = "transcript_quality"
            case wavPath = "wav_path"
        }
    }

    struct SpeakerMapEntry: Codable, Equatable {
        var name: String
        var source: String   // "deterministic" | "llm" | "enrollment" | "manual"
    }

    var frontmatter: Frontmatter
    var body: String

    // MARK: - Encoding

    /// Render to the full file string: `---\n<yaml>\n---\n\n<body>\n`.
    /// Yams handles all string-escape edge cases (quotes, multiline, special
    /// chars), so callers can pass arbitrary text in fields without breaking
    /// the file format.
    func render() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        let yaml = try encoder.encode(frontmatter)
        // Yams puts a trailing newline after the document; strip it so we
        // can inject our own delimiter consistently.
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        var out = "---\n"
        out += trimmed
        out += "\n---\n\n"
        out += body
        if !body.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Inverse of `render()`. Splits the file at the frontmatter delimiters
    /// and decodes the YAML. Throws on malformed input.
    static func parse(_ source: String) throws -> CorpusEntry {
        let lines = source.components(separatedBy: "\n")
        guard lines.first == "---" else {
            throw CorpusError.missingFrontmatter
        }
        // Find the closing `---` after the opening one.
        var endIdx: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" {
                endIdx = i
                break
            }
        }
        guard let end = endIdx else {
            throw CorpusError.unterminatedFrontmatter
        }
        let yamlSource = lines[1..<end].joined(separator: "\n")
        let decoder = YAMLDecoder()
        let fm = try decoder.decode(Frontmatter.self, from: yamlSource)
        // Body starts after the closing delimiter; skip a single blank
        // separator line if present so round-trips are clean.
        var bodyStart = end + 1
        if bodyStart < lines.count, lines[bodyStart].isEmpty {
            bodyStart += 1
        }
        let bodyLines = bodyStart < lines.count ? Array(lines[bodyStart...]) : []
        // Drop a single trailing empty line (the one `render()` adds).
        var trimmed = bodyLines
        if let last = trimmed.last, last.isEmpty {
            trimmed.removeLast()
        }
        return CorpusEntry(frontmatter: fm, body: trimmed.joined(separator: "\n"))
    }
}

enum CorpusError: Error, CustomStringConvertible {
    case missingFrontmatter
    case unterminatedFrontmatter
    case ioFailure(String)
    case malformedJSONLLine(String)

    var description: String {
        switch self {
        case .missingFrontmatter:
            return "Markdown file does not start with a `---` frontmatter delimiter."
        case .unterminatedFrontmatter:
            return "Frontmatter delimiter `---` was not closed."
        case .ioFailure(let detail):
            return "Corpus IO failure: \(detail)"
        case .malformedJSONLLine(let detail):
            return "Malformed JSONL event line: \(detail)"
        }
    }
}
