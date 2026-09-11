import Foundation

/// One turn of an archived `chat.md`, read back so the Sessions window can
/// draw a past Assist chat in the thread grammar (question pills on the
/// right, answers as prose on the left), read only.
public struct ArchivedChatTurn: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant }

    public let id: Int
    public let role: Role
    /// The canned action that asked ("Assist", "Recap"); nil for a typed
    /// question ("Ask") and for answers.
    public let action: String?
    public let usedTranscript: Bool
    public let usedScreen: Bool
    /// `@` vault files sent with the question.
    public let referencedPaths: [String]
    public let text: String

    public init(
        id: Int,
        role: Role,
        action: String? = nil,
        usedTranscript: Bool = false,
        usedScreen: Bool = false,
        referencedPaths: [String] = [],
        text: String
    ) {
        self.id = id
        self.role = role
        self.action = action
        self.usedTranscript = usedTranscript
        self.usedScreen = usedScreen
        self.referencedPaths = referencedPaths
        self.text = text
    }

    /// What the question pill says: a canned action's name, never its
    /// internal prompt; a typed question or slash command as typed.
    public var pillText: String {
        guard let action, !text.hasPrefix("/") else { return text }
        return action
    }
}

/// Reads the `chat.md` shape `SessionArchive` writes: a `**You**` or
/// `**Assistant**` line (with optional `_(Action, transcript, screen)_`
/// tags), a blank line, an optional "Referenced files:" list, then the text.
public enum ArchivedChat {
    public static func turns(fromMarkdown markdown: String) -> [ArchivedChatTurn] {
        var body = markdown
        if body.hasPrefix("---"), let end = body.range(of: "\n---\n") {
            body = String(body[end.upperBound...])
        }

        var turns: [ArchivedChatTurn] = []
        var header: (role: ArchivedChatTurn.Role, tags: [String])?
        var lines: [String] = []

        func flush() {
            guard let current = header else { return }
            var textLines = lines
            var paths: [String] = []
            // "Referenced files:" then "- `path`" rows, then a blank line.
            if let start = textLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               textLines[start].trimmingCharacters(in: .whitespaces) == "Referenced files:" {
                var index = start + 1
                while index < textLines.count {
                    let row = textLines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("- ") else { break }
                    paths.append(row.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "` ")))
                    index += 1
                }
                textLines.removeSubrange(start..<index)
            }
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = current.tags.map { $0.lowercased() }
            let action = current.tags.first.flatMap { tag -> String? in
                let low = tag.lowercased()
                return (low == "transcript" || low == "screen" || low == "ask") ? nil : tag
            }
            turns.append(ArchivedChatTurn(
                id: turns.count,
                role: current.role,
                action: current.role == .user ? action : nil,
                usedTranscript: lowered.contains("transcript"),
                usedScreen: lowered.contains("screen"),
                referencedPaths: paths,
                text: text
            ))
            header = nil
            lines = []
        }

        for line in body.components(separatedBy: "\n") {
            if let parsed = speakerLine(line) {
                flush()
                header = parsed
            } else if header != nil {
                lines.append(line)
            }
        }
        flush()
        return turns.filter { !$0.text.isEmpty || $0.action != nil }
    }

    /// `**You** _(Assist, transcript)_` → (.user, ["Assist", "transcript"]).
    static func speakerLine(_ line: String) -> (role: ArchivedChatTurn.Role, tags: [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let role: ArchivedChatTurn.Role
        let rest: Substring
        if trimmed.hasPrefix("**You**") {
            role = .user
            rest = trimmed.dropFirst("**You**".count)
        } else if trimmed.hasPrefix("**Assistant**") {
            role = .assistant
            rest = trimmed.dropFirst("**Assistant**".count)
        } else {
            return nil
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if tail.isEmpty { return (role, []) }
        guard tail.hasPrefix("_("), tail.hasSuffix(")_") else { return nil }
        let inner = tail.dropFirst(2).dropLast(2)
        let tags = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (role, tags)
    }
}
