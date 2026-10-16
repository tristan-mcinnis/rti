import Foundation

/// A read-only snapshot of an ARCHIVED session's own identity, taken from its
/// folder at generation time.
///
/// Every field comes from the archive (`session.json`, `speaker-names.json`),
/// never from the live coordinator or the currently open mode. Generating an
/// output for a past session therefore cannot be contaminated by whatever
/// session or mode happens to be active now. Pure value type, so the prompt
/// context it builds is unit-tested directly.
public struct SessionOutputSnapshot: Equatable, Sendable {
    public let sessionFolder: String
    public let sessionID: String?
    public let mode: String?
    public let workstream: String?
    public let calendarTitle: String?
    public let speakerNames: [String: String]

    public init(
        sessionFolder: String,
        sessionID: String? = nil,
        mode: String? = nil,
        workstream: String? = nil,
        calendarTitle: String? = nil,
        speakerNames: [String: String] = [:]
    ) {
        self.sessionFolder = sessionFolder
        self.sessionID = sessionID
        self.mode = mode
        self.workstream = workstream
        self.calendarTitle = calendarTitle
        self.speakerNames = speakerNames
    }

    /// A one-line-per-fact context block for the prompt; empty when there is
    /// nothing. Names are sorted so the block is deterministic.
    public var promptContext: String {
        var parts: [String] = []
        if let mode = mode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
            parts.append("session type: \(mode)")
        }
        if let workstream = workstream?.trimmingCharacters(in: .whitespacesAndNewlines), !workstream.isEmpty {
            parts.append("workstream: \(workstream)")
        }
        if let calendarTitle = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !calendarTitle.isEmpty {
            parts.append("calendar title: \(calendarTitle)")
        }
        let named = speakerNames
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) is \($0.value.trimmingCharacters(in: .whitespacesAndNewlines))" }
        if !named.isEmpty {
            parts.append("known speakers: \(named.joined(separator: "; "))")
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }
}

/// Pure prompt assembly for a saved-meeting output.
///
/// Kept in RTICore with no I/O so the exact text sent to the model — the
/// instruction, the optional context hint, and the transcript fence — is
/// unit-tested without a provider, a file read, or a network call.
public enum SessionOutputPrompt {
    /// The one prompt for one output: the recipe's instruction, an optional
    /// saved-record context hint, and the transcript, each in its own clearly
    /// labelled block. The transcript is fenced as machine-generated and the
    /// model is told to work only from it.
    public static func text(instruction: String, context: String, transcript: String) -> String {
        var sections = [instruction.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Session context (from the saved record; a hint only, not proof of attendance):\n\(context)")
        }
        sections.append(
            "Transcript of the saved session (machine-generated; names and numbers may be garbled). "
                + "Work only from this text. Never invent facts, commitments, or quotes:\n\n\(transcript)"
        )
        return sections.joined(separator: "\n\n")
    }

    /// Drop a leading `---` … `---` frontmatter block so the model reads only
    /// the transcript body. Text without frontmatter is returned unchanged.
    public static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
    }

    /// Rename only canonical timestamped speaker labels, never the words spoken.
    /// In particular, naming "You" must not rewrite "You should…" inside a quote.
    public static func applyingSpeakerNames(to text: String, names: [String: String]) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(?m)^(`[^`\n]+`[ \t]+\*\*)([^*\n]+)(:\*\*)"#) else { return text }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 2), in: text),
                  let name = names[String(text[range])]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            result.replaceCharacters(in: match.range(at: 2), with: name)
        }
        return result as String
    }
}
