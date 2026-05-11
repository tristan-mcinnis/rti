import Foundation

/// Cross-session Q&A: lets the user ask questions that span their entire
/// meeting corpus. Retrieves the top-K relevant sessions via FTS, plus the
/// most-recent N sessions for temporal questions, then asks the LLM to
/// answer with explicit `[Session Title]` citations the UI can hyperlink
/// back to the source.
@MainActor
final class AskCorpusController: ObservableObject {
    static let shared = AskCorpusController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [Entry] = []
    /// Sessions referenced in the most recent answer. The view uses this to
    /// render clickable citation chips below each assistant turn.
    @Published private(set) var citationsForLast: [Citation] = []
    /// The conversation currently displayed. Nil = unsaved (no messages yet).
    @Published private(set) var conversationId: String?
    @Published private(set) var conversationTitle: String?

    private let request: LLMRequest

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    struct Entry: Identifiable {
        let id = UUID()
        let role: String   // "user" | "assistant"
        var text: String
        var citations: [Citation] = []
        var createdAt: Date = Date()
    }

    struct Citation: Identifiable, Hashable {
        var id: String { sessionId }
        let sessionId: String
        let title: String
    }

    /// Start a fresh, unsaved conversation. Existing chat (if any) is
    /// already persisted to disk so it shows up in history.
    func newChat() {
        request.cancel()
        messages = []
        lastError = nil
        citationsForLast = []
        isGenerating = false
        conversationId = nil
        conversationTitle = nil
    }

    /// Cancel an in-flight stream. Leaves the partial assistant message
    /// in place — the user can re-ask or just continue.
    func stop() {
        request.cancel()
        isGenerating = false
    }

    /// Replace the current conversation with one loaded from disk.
    func load(_ conversation: AskCorpusConversation) {
        request.cancel()
        isGenerating = false
        lastError = nil
        conversationId = conversation.id
        conversationTitle = conversation.title
        messages = conversation.messages.map { stored in
            Entry(
                role: stored.role,
                text: stored.text,
                citations: stored.citations.map { Citation(sessionId: $0.sessionId, title: $0.title) },
                createdAt: stored.createdAt
            )
        }
        citationsForLast = messages.last?.citations ?? []
    }

    /// Compatibility shim for existing callers — same as newChat.
    func clear() { newChat() }

    func ask(question: String) {
        guard !isGenerating else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        lastError = nil

        messages.append(Entry(role: "user", text: trimmed))

        let retrieved = retrieve(forQuestion: trimmed)
        guard !retrieved.candidates.isEmpty else {
            lastError = "No meetings have been recorded yet. Record a session first."
            isGenerating = false
            messages.removeLast()
            return
        }

        let context = buildContext(retrieved)
        let candidateCitations = retrieved.candidates.map {
            Citation(sessionId: $0.session.id, title: $0.title)
        }
        let systemPrompt = """
        You are RTI, the user's meeting assistant. The user is asking a question that may span multiple past meetings.
        Use ONLY the meeting excerpts provided below. If the answer isn't there, say so plainly.

        Cite sources inline using the EXACT bracket notation `[Session Title]` whenever you reference content from a specific meeting. Use the title verbatim from the excerpt headers. Multiple citations OK.

        Format with light markdown (bold for emphasis, bullets/numbers for lists). Keep paragraphs short.

        Meeting excerpts:
        \(context)
        """

        // Build the API message list with prior conversation context so
        // follow-up questions ("tell me more", "what about Kline?") keep
        // working without the user repeating themselves.
        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: systemPrompt)]
        // Include the last 6 prior turns (~3 exchanges) before the new question.
        let priorTurns = messages.dropLast().suffix(6)
        for turn in priorTurns {
            apiMessages.append(LLMMessage(role: turn.role, content: turn.text))
        }
        apiMessages.append(LLMMessage(role: "user", content: trimmed))

        var assistantEntry = Entry(role: "assistant", text: "")
        // Citations are computed on completion (parsed from the answer).
        // While streaming, no chips show — keeps the UI honest.
        assistantEntry.citations = []
        messages.append(assistantEntry)
        let entryId = assistantEntry.id

        request.stream(
            messages: apiMessages,
            smart: false,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        self.messages[idx].text += delta
                    }
                }
            },
            onError: { [weak self] errorMessage, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastError = errorMessage
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        self.messages.remove(at: idx)
                    }
                    self.isGenerating = false
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isGenerating = false
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        let body = self.messages[idx].text
                        let cited = Self.actualCitations(from: body, candidates: candidateCitations)
                        self.messages[idx].citations = cited
                        self.citationsForLast = cited
                    }
                    self.persistToHistory()
                }
            }
        )
    }

    // MARK: - Persistence

    /// Write the current conversation to disk (creates on first turn,
    /// updates in place on subsequent turns). Title is derived from the
    /// first user message; falls back to "Untitled" if empty.
    private func persistToHistory() {
        guard !messages.isEmpty else { return }
        let now = Date()
        if conversationId == nil {
            conversationId = UUID().uuidString
            conversationTitle = Self.deriveTitle(from: messages)
        }
        guard let id = conversationId else { return }
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

    private static func deriveTitle(from messages: [Entry]) -> String {
        guard let firstUser = messages.first(where: { $0.role == "user" })?.text else {
            return "Untitled"
        }
        let trimmed = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        let cut = trimmed.prefix(60)
        // Try to end on a word boundary.
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(trimmed[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
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

    /// Parse the answer for `[Session Title]` occurrences and intersect
    /// with the candidate set. If the model didn't cite anything, fall
    /// back to the top 3 candidates so the user still gets jump-points.
    private static func actualCitations(from body: String, candidates: [Citation]) -> [Citation] {
        var cited: [Citation] = []
        var seen = Set<String>()
        for c in candidates {
            if body.contains("[\(c.title)]"), !seen.contains(c.sessionId) {
                cited.append(c)
                seen.insert(c.sessionId)
            }
        }
        if cited.isEmpty { return Array(candidates.prefix(3)) }
        return cited
    }

    // MARK: - Retrieval

    private struct Candidate {
        let session: Session
        let title: String
        let snippet: String?
        let summary: String?
    }

    private struct Retrieved {
        let candidates: [Candidate]
    }

    /// Hybrid retrieval: FTS top-K for relevance, plus the most-recent few
    /// for temporal queries like "what did I work on this week?". Deduped
    /// by session id, capped at 8 sessions to keep the prompt bounded.
    private func retrieve(forQuestion question: String) -> Retrieved {
        var seen = Set<String>()
        var out: [Candidate] = []

        for hit in SessionSearch.search(query: question, limit: 6) {
            guard !seen.contains(hit.session.id) else { continue }
            seen.insert(hit.session.id)
            out.append(Candidate(
                session: hit.session,
                title: displayTitle(hit.session),
                snippet: hit.snippet,
                summary: CorpusBackedStore.summary(forSessionId: hit.session.id)?.summaryText
            ))
        }

        let recent = CorpusBackedStore.allMarkdownSessions()
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(4)
        for s in recent {
            guard !seen.contains(s.id) else { continue }
            seen.insert(s.id)
            out.append(Candidate(
                session: s,
                title: displayTitle(s),
                snippet: nil,
                summary: CorpusBackedStore.summary(forSessionId: s.id)?.summaryText
            ))
        }

        return Retrieved(candidates: Array(out.prefix(8)))
    }

    private func displayTitle(_ session: Session) -> String {
        if let t = session.calendarTitle, !t.isEmpty { return t }
        if let t = session.title, !t.isEmpty { return t }
        return "Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func buildContext(_ retrieved: Retrieved) -> String {
        var parts: [String] = []
        for c in retrieved.candidates {
            var block = "### [\(c.title)]\n"
            block += "Date: \(c.session.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
            if let summary = c.summary, !summary.isEmpty {
                block += "Summary:\n\(summary.prefix(1500))\n"
            }
            if let snippet = c.snippet, !snippet.isEmpty {
                block += "Match: \(snippet)\n"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n---\n")
    }
}
