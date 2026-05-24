import Foundation
import Observation

/// Shared types and lifecycle for corpus-backed chat controllers: a user
/// asks a question, the controller retrieves relevant sessions, streams
/// an answer from the LLM, parses `[Session Title]` citations out of the
/// reply, and persists the conversation.
///
/// Two concrete controllers subclass this:
///  - `AskCorpusController`: the corpus-wide singleton (`shared`).
///  - `ProjectQAController`: per-project instance scoped to a project's
///    member sessions.
///
/// Subclasses customise four things — retrieval, system prompt body,
/// the "no candidates" error message, and on-disk persistence — by
/// overriding the open hooks below. Everything else (stream wiring,
/// citation parsing, title derivation, prior-turn windowing, message
/// state) lives once, here.

struct CorpusChatEntry: Identifiable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    var text: String
    var citations: [CorpusChatCitation] = []
    var createdAt: Date = Date()
}

struct CorpusChatCitation: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let title: String
}

struct CorpusChatCandidate {
    let session: Session
    let title: String
    let snippet: String?
    let summary: String?
}

@Observable @MainActor
class CorpusChatController {
    private(set) var isGenerating = false
    private(set) var lastError: String?
    private(set) var messages: [CorpusChatEntry] = []
    private(set) var citationsForLast: [CorpusChatCitation] = []
    private(set) var conversationId: String?
    private(set) var conversationTitle: String?

    fileprivate let request: LLMRequest

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    // MARK: - Lifecycle

    func newChat() {
        request.cancel()
        messages = []
        lastError = nil
        citationsForLast = []
        isGenerating = false
        conversationId = nil
        conversationTitle = nil
    }

    func stop() {
        request.cancel()
        isGenerating = false
    }

    /// Render the conversation as markdown for clipboard / file export.
    /// Generic over both Ask and Project chats — subclasses can override
    /// to add metadata (e.g. created-at) but the default is sufficient.
    func exportMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(conversationTitle ?? "Chat")")
        lines.append("")
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

    // MARK: - Subclass-only restoration helpers

    /// Subclasses call this from their own `load(_:)` after decoding from
    /// disk. Centralised so the published-state contract (`citationsForLast`
    /// must mirror the last assistant message's citations) doesn't drift
    /// between controllers.
    fileprivate func adoptRestored(
        id: String,
        title: String,
        messages: [CorpusChatEntry]
    ) {
        request.cancel()
        isGenerating = false
        lastError = nil
        conversationId = id
        conversationTitle = title
        self.messages = messages
        citationsForLast = messages.last?.citations ?? []
    }

    // MARK: - Ask

    func ask(question: String) {
        guard !isGenerating else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true
        lastError = nil
        messages.append(CorpusChatEntry(role: "user", text: trimmed))

        let candidates: [CorpusChatCandidate]
        do {
            candidates = try retrieve(forQuestion: trimmed)
        } catch let error as CorpusChatError {
            lastError = error.message
            isGenerating = false
            messages.removeLast()
            return
        } catch {
            lastError = "Retrieval failed: \(error.localizedDescription)"
            isGenerating = false
            messages.removeLast()
            return
        }

        let context = Self.buildContext(from: candidates)
        let candidateCitations = candidates.map {
            CorpusChatCitation(sessionId: $0.session.id, title: $0.title)
        }
        let systemPrompt = makeSystemPrompt(context: context)

        // System block (prompt + glossary, in that order) is assembled by
        // PromptBuilder so the glossary-injection and ordering rules live in
        // one place across every chat surface, not re-implemented here.
        var apiMessages = PromptBuilder.buildSystemMessages(context: PromptContext(
            baseSystemPrompt: systemPrompt,
            glossaryFragment: GlossaryStore.shared.systemPromptFragment
        ))
        // Last 6 prior turns (~3 exchanges) for follow-up coherence.
        let priorTurns = messages.dropLast().suffix(6)
        for turn in priorTurns {
            apiMessages.append(LLMMessage(role: turn.role, content: turn.text))
        }
        apiMessages.append(LLMMessage(role: "user", content: trimmed))

        let assistantEntry = CorpusChatEntry(role: "assistant", text: "")
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
                    self.didEncounterStreamError(errorMessage)
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
                        self.didFinishAnswer(body: body, candidateCount: candidateCitations.count, citedCount: cited.count)
                    }
                    self.persistAfterTurn()
                }
            }
        )
    }

    // MARK: - Subclass hooks

    /// Return candidates the LLM should answer from. Throw
    /// `CorpusChatError` with a user-facing message to short-circuit the
    /// turn (e.g. "no meetings recorded yet").
    func retrieve(forQuestion question: String) throws -> [CorpusChatCandidate] {
        return []
    }

    /// Build the system prompt body. The shared retrieval context is
    /// already rendered; subclasses decide where to splice it.
    func makeSystemPrompt(context: String) -> String {
        return context
    }

    /// Persist the current conversation. Called after each completed turn.
    /// Subclasses own their on-disk format; the base only guarantees that
    /// `conversationId` and `conversationTitle` are populated by this
    /// point.
    func persistConversation() {}

    /// Hook for subclass logging on stream error. Default is silent.
    func didEncounterStreamError(_ message: String) {}

    /// Hook for subclass logging on stream completion. Default is silent.
    func didFinishAnswer(body: String, candidateCount: Int, citedCount: Int) {}

    // MARK: - Persistence-id management

    private func persistAfterTurn() {
        guard !messages.isEmpty else { return }
        if conversationId == nil {
            conversationId = UUID().uuidString
            conversationTitle = Self.deriveTitle(from: messages)
        }
        persistConversation()
    }

    // MARK: - Helpers (shared)

    /// Parse `[Session Title]` occurrences out of the answer. If the model
    /// didn't cite anything, fall back to the top 3 candidates so the user
    /// still has jump-points to verify against the source.
    static func actualCitations(
        from body: String,
        candidates: [CorpusChatCitation]
    ) -> [CorpusChatCitation] {
        var cited: [CorpusChatCitation] = []
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

    static func deriveTitle(from messages: [CorpusChatEntry]) -> String {
        guard let firstUser = messages.first(where: { $0.role == "user" })?.text else {
            return "Untitled"
        }
        let trimmed = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        let cut = trimmed.prefix(60)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(trimmed[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    static func displayTitle(for session: Session) -> String {
        if let t = session.calendarTitle, !t.isEmpty { return t }
        if let t = session.title, !t.isEmpty { return t }
        return "Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Result of `assembleCandidates`: the capped candidate list plus the
    /// counts subclasses log (`hybrid` came from retrieval, `recency` from
    /// the backfill, `dropped` exceeded the cap).
    struct CandidateAssembly {
        let candidates: [CorpusChatCandidate]
        let hybridCount: Int
        let recencyCount: Int
        let dropped: Int
    }

    /// Shared retrieval-assembly recipe for every corpus-backed chat
    /// surface: pull hybrid hits (BM25 + dense, RRF-merged), dedupe, then
    /// backfill remaining slots with the most-recent sessions retrieval
    /// missed — recency biases toward "what did we just discuss". Each
    /// session is packaged into a `CorpusChatCandidate` with its title,
    /// best snippet, and summary. Subclasses supply only the scope
    /// (`includes`) and the caps; `HybridRetriever` falls back to FTS-only
    /// when the dense index isn't ready.
    ///
    /// - Parameters:
    ///   - hybridLimit: how many hits to request from `HybridRetriever`.
    ///   - cap: hard upper bound on candidates returned.
    ///   - includes: scope predicate on session id (default: everything).
    ///   - recencyLimit: cap on how many recent sessions to consider for
    ///     backfill before dedup (nil = all in scope).
    static func assembleCandidates(
        question: String,
        hybridLimit: Int,
        cap: Int,
        includes: (String) -> Bool = { _ in true },
        recencyLimit: Int? = nil
    ) -> CandidateAssembly {
        var seen = Set<String>()
        var out: [CorpusChatCandidate] = []

        for hit in HybridRetriever.retrieve(query: question, limit: hybridLimit)
            where includes(hit.session.id) {
            guard seen.insert(hit.session.id).inserted else { continue }
            out.append(CorpusChatCandidate(
                session: hit.session,
                title: displayTitle(for: hit.session),
                snippet: hit.bestSnippet,
                summary: CorpusBackedStore.summary(forSessionId: hit.session.id)?.summaryText
            ))
        }
        let hybridCount = out.count

        var recencyPool = CorpusBackedStore.allMarkdownSessions()
            .filter { includes($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        if let recencyLimit { recencyPool = Array(recencyPool.prefix(recencyLimit)) }
        for s in recencyPool where seen.insert(s.id).inserted {
            out.append(CorpusChatCandidate(
                session: s,
                title: displayTitle(for: s),
                snippet: nil,
                summary: CorpusBackedStore.summary(forSessionId: s.id)?.summaryText
            ))
        }
        let recencyCount = out.count - hybridCount

        return CandidateAssembly(
            candidates: Array(out.prefix(cap)),
            hybridCount: hybridCount,
            recencyCount: recencyCount,
            dropped: max(0, out.count - cap)
        )
    }

    static func buildContext(from candidates: [CorpusChatCandidate]) -> String {
        var parts: [String] = []
        for c in candidates {
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

/// Subclasses throw this from `retrieve` to abort the turn with a
/// user-facing message — the base controller surfaces `.message` in
/// `lastError` and rolls back the user-typed message.
struct CorpusChatError: Error {
    let message: String
}

extension CorpusChatController {
    /// Subclass entrypoint that bypasses the `fileprivate` visibility on
    /// `adoptRestored` — public so views can call `load` on subclasses.
    func adoptRestoredConversation(
        id: String,
        title: String,
        messages: [CorpusChatEntry]
    ) {
        adoptRestored(id: id, title: title, messages: messages)
    }
}
