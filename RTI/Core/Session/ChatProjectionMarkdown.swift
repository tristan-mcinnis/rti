import Foundation

/// One stored chat as it appears in a session's compatibility projection.
///
/// The ids are exact: `thread` is the conversation record's own id, `turn` is
/// the turn record's own id. Nothing here is inferred from dates, so a session
/// with several chats never invents boundaries between them.
public enum ChatProjectionMarkdown {
    public struct Turn: Equatable, Sendable {
        public let id: String
        public let role: String
        public let text: String
        public let createdAt: Date?
        /// The turn's request status ("completed", "cancelled", …), when known,
        /// so an interrupted answer is visible in the export.
        public let status: String?

        public init(id: String, role: String, text: String, createdAt: Date? = nil, status: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
            self.status = status
        }
    }

    public struct Thread: Equatable, Sendable {
        public let id: String
        public let title: String?
        public let createdAt: Date?
        public let turns: [Turn]

        public init(id: String, title: String? = nil, createdAt: Date? = nil, turns: [Turn] = []) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.turns = turns
        }
    }

    /// The body of `chat.md` when the recording has structured chats.
    ///
    /// Every thread is listed with its own id and every turn with its own id,
    /// so a later reader can find the owning record. `unreadableChats` is
    /// reported in the file rather than being silently absent: a chat that
    /// could not be read was not deleted, and the projection must not imply it
    /// was.
    public static func render(
        threads: [Thread],
        startedAt: Date,
        endedAt: Date,
        unreadableChats: Int = 0,
        header: String
    ) -> String {
        var lines: [String] = ["# Chat", "", header, ""]

        if threads.count > 1 {
            lines.append("\(threads.count) chats in this recording. Each turn keeps its own id.")
            lines.append("")
        }

        for (index, thread) in threads.enumerated() {
            lines.append("## Chat \(index + 1)" + (thread.title.map { ": \($0)" } ?? ""))
            lines.append("")
            lines.append("thread: `\(thread.id)`")
            lines.append("")
            for turn in thread.turns {
                let speaker = turn.role == "assistant" ? "Assistant" : "You"
                var note = "turn `\(turn.id)`"
                if let status = turn.status, status != "completed" { note += ", \(status)" }
                lines.append("**\(speaker)** _(\(note))_")
                lines.append("")
                lines.append(turn.text)
                lines.append("")
            }
        }

        if unreadableChats > 0 {
            let noun = unreadableChats == 1 ? "chat" : "chats"
            lines.append("_\(unreadableChats) stored \(noun) in this recording could not be read and \(unreadableChats == 1 ? "is" : "are") not shown here. Nothing was removed._")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// The same threads as the assistant-chat section of the meeting sidecar.
    public static func renderSection(threads: [Thread], unreadableChats: Int = 0) -> [String] {
        guard !threads.isEmpty || unreadableChats > 0 else { return [] }
        var lines: [String] = ["## Assistant chat", ""]
        if threads.count > 1 {
            lines.append("\(threads.count) chats in this recording. Each turn keeps its own id.")
            lines.append("")
        }
        for (index, thread) in threads.enumerated() {
            lines.append("### Chat \(index + 1)" + (thread.title.map { ": \($0)" } ?? ""))
            lines.append("")
            lines.append("thread: `\(thread.id)`")
            lines.append("")
            for turn in thread.turns {
                let speaker = turn.role == "assistant" ? "Assistant" : "You"
                var note = "turn `\(turn.id)`"
                if let status = turn.status, status != "completed" { note += ", \(status)" }
                lines.append("**\(speaker)** _(\(note))_")
                lines.append("")
                lines.append(turn.text)
                lines.append("")
            }
        }
        if unreadableChats > 0 {
            let noun = unreadableChats == 1 ? "chat" : "chats"
            lines.append("_\(unreadableChats) stored \(noun) in this recording could not be read and \(unreadableChats == 1 ? "is" : "are") not shown here. Nothing was removed._")
            lines.append("")
        }
        return lines
    }
}
