import Foundation

/// Cross-session Q&A: lets the user ask questions that span their entire
/// meeting corpus. Retrieves the top-K relevant sessions via FTS, plus the
/// most-recent N sessions for temporal questions, then asks the LLM to
/// answer with explicit `[Session Title]` citations the UI can hyperlink
/// back to the source.
///
/// All streaming/state/citation logic lives in `CorpusChatController`.
/// This subclass only supplies corpus-wide retrieval, the system prompt,
/// and conversation persistence.
@MainActor
final class AskCorpusController: CorpusChatController {
    static let shared = AskCorpusController()

    // Preserved nesting so existing view call sites (`AskCorpusController.Entry`,
    // `AskCorpusController.Citation`) keep compiling.
    typealias Entry = CorpusChatEntry
    typealias Citation = CorpusChatCitation

    /// Compatibility shim for existing callers — same as `newChat()`.
    func clear() { newChat() }

    /// Replace the current conversation with one loaded from disk.
    func load(_ conversation: AskCorpusConversation) {
        let restored = conversation.messages.map { stored in
            CorpusChatEntry(
                role: stored.role,
                text: stored.text,
                citations: stored.citations.map { Citation(sessionId: $0.sessionId, title: $0.title) },
                createdAt: stored.createdAt
            )
        }
        adoptRestoredConversation(id: conversation.id, title: conversation.title, messages: restored)
    }

    // MARK: - Strategy

    override func retrieve(forQuestion question: String) throws -> [CorpusChatCandidate] {
        var seen = Set<String>()
        var out: [CorpusChatCandidate] = []

        for hit in SessionSearch.search(query: question, limit: 6) {
            guard !seen.contains(hit.session.id) else { continue }
            seen.insert(hit.session.id)
            out.append(CorpusChatCandidate(
                session: hit.session,
                title: Self.displayTitle(for: hit.session),
                snippet: hit.snippet,
                summary: CorpusBackedStore.summary(forSessionId: hit.session.id)?.summaryText
            ))
        }

        let recent = CorpusBackedStore.allMarkdownSessions()
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(4)
        for s in recent where !seen.contains(s.id) {
            seen.insert(s.id)
            out.append(CorpusChatCandidate(
                session: s,
                title: Self.displayTitle(for: s),
                snippet: nil,
                summary: CorpusBackedStore.summary(forSessionId: s.id)?.summaryText
            ))
        }

        let final = Array(out.prefix(8))
        guard !final.isEmpty else {
            throw CorpusChatError(message: "No meetings have been recorded yet. Record a session first.")
        }
        return final
    }

    override func makeSystemPrompt(context: String) -> String {
        """
        You are RTI, the user's meeting assistant. The user is asking a question that may span multiple past meetings.
        Use ONLY the meeting excerpts provided below. If the answer isn't there, say so plainly.

        Cite sources inline using the EXACT bracket notation `[Session Title]` whenever you reference content from a specific meeting. Use the title verbatim from the excerpt headers. Multiple citations OK.

        Format with light markdown (bold for emphasis, bullets/numbers for lists). Keep paragraphs short.

        Meeting excerpts:
        \(context)
        """
    }

    override func persistConversation() {
        guard let id = conversationId, !messages.isEmpty else { return }
        let now = Date()
        let conversation = AskCorpusConversation(
            id: id,
            title: conversationTitle ?? "Untitled",
            createdAt: messages.first?.createdAt ?? now,
            updatedAt: now,
            messages: messages.map { entry in
                AskCorpusConversation.StoredEntry(
                    role: entry.role,
                    text: entry.text,
                    createdAt: entry.createdAt,
                    citations: entry.citations.map {
                        AskCorpusConversation.StoredCitation(sessionId: $0.sessionId, title: $0.title)
                    }
                )
            }
        )
        AskCorpusHistoryStore.save(conversation)
    }

    // MARK: - Export

    /// Render the conversation as markdown for clipboard/file export.
    func exportMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines: [String] = []
        lines.append("# \(conversationTitle ?? "Ask Corpus")")
        lines.append("")
        if let id = conversationId, let conv = AskCorpusHistoryStore.list().first(where: { $0.id == id }) {
            lines.append("_\(formatter.string(from: conv.createdAt))_")
            lines.append("")
        }
        for msg in messages {
            let who = msg.role == "user" ? "**You**" : "**RTI**"
            lines.append("### \(who)")
            lines.append(msg.text)
            if msg.role == "assistant", !msg.citations.isEmpty {
                let cites = msg.citations.map { "[\($0.title)]" }.joined(separator: ", ")
                lines.append("")
                lines.append("_Sources: \(cites)_")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
