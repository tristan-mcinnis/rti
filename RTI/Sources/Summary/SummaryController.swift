import Foundation
import Observation

@Observable @MainActor
final class SummaryController {
    static let shared = SummaryController()

    private(set) var isGenerating = false
    private(set) var lastError: String?

    private let request: LLMRequest
    /// Per-session in-memory cache. Keyed by session id, populated on
    /// generation, consumed by `CorpusManager.renderSession` at session-end
    /// and by `CorpusBackedStore.summary(forSessionId:)` while a session is
    /// in-flight. Markdown becomes the durable record once written; the
    /// cache is purged after a successful render.
    private var cache: [String: SessionSummary] = [:]

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    /// Cancel an in-flight summary generation. Safe to call when nothing is
    /// running. Flips isGenerating immediately so the UI returns to its
    /// empty state without waiting for the URLSession to unwind.
    func cancel() {
        request.cancel()
        isGenerating = false
    }

    private static let summaryPrompt = """
    You are an AI meeting assistant. Below is the full transcript of a meeting conversation.

    If the transcript begins with a "## User notes" block, those are authoritative corrections
    from the user (e.g. correcting names or facts). Apply them throughout the summary — don't
    repeat the uncorrected forms.

    Produce a structured meeting summary using this exact format. Be thorough but concise.

    ## Summary
    Write a 2-3 paragraph factual summary covering what was discussed, the overall arc of the conversation, and any major conclusions reached. Do NOT list action items here — put those in the Action Items section.

    ## Key Topics
    - List the main topics discussed, one per bullet. Be specific; avoid vague labels.

    ## Decisions Made
    - List each decision that was made, with context for why (if evident). One per bullet.

    ## Action Items
    Only extract items that meet ALL of these criteria:
    - Someone is explicitly named as responsible (skip "we should…" items)
    - A deadline or timeframe was mentioned (skip "soon" / "later")
    - The item was NOT resolved during the meeting itself
    - The item has a concrete deliverable (skip "think about" / "explore")
    List each as: `- [ ] Task description — Owner: @name — Due: date/timeframe`

    ## Open Questions
    - List any open questions raised during the meeting that still need answers.

    ## Next Steps
    - List what happens next: follow-up meetings, deliverables, check-ins.

    If a section truly has no content, write "None." under that heading.

    Transcript:
    """

    @discardableResult
    func generateSummary(for sessionId: String) async -> SessionSummary? {
        guard !isGenerating else { return cache[sessionId] }
        cancel()
        isGenerating = true
        lastError = nil

        let transcript = TranscriptContext.text(forSessionId: sessionId)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "No transcript content to summarize."
            isGenerating = false
            return nil
        }

        let fullPrompt = Self.summaryPrompt + "\n" + transcript
        let messages = [LLMMessage(role: "user", content: fullPrompt)]

        guard let fullResponse = await request.collectAsync(messages: messages, smart: true),
              !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Summary generation returned empty response."
            isGenerating = false
            return nil
        }
        let parsed = Self.parseSections(from: fullResponse)
        let combinedFollowUps = SummaryFormatting.combineFollowUps(openQuestions: parsed["Open Questions"], nextSteps: parsed["Next Steps"])
        let summary = SessionSummary(
            id: UUID().uuidString,
            sessionId: sessionId,
            summaryText: fullResponse,
            actionItems: parsed["Action Items"],
            keyTopics: parsed["Key Topics"],
            decisions: parsed["Decisions Made"],
            followUps: combinedFollowUps,
            rawResponse: fullResponse,
            createdAt: Date(),
            regeneratedAt: nil
        )
        cache[sessionId] = summary
        isGenerating = false
        return summary
    }

    /// In-memory cache lookup. Returns the most recently generated
    /// summary for `sessionId` if `generateSummary` has run during this
    /// app lifetime; nil otherwise. Callers that need the durable summary
    /// for a previously-rendered session should read it from markdown via
    /// `CorpusBackedStore.summary(forSessionId:)` instead.
    func cachedSummary(forSessionId id: String) -> SessionSummary? {
        cache[id]
    }

    /// Drop the cache entry once the durable markdown has been written.
    /// Called from `CorpusManager` post-render.
    func purgeCache(forSessionId id: String) {
        cache.removeValue(forKey: id)
    }

    func loadSummary(for sessionId: String) -> SessionSummary? {
        if let cached = cache[sessionId] { return cached }
        return CorpusBackedStore.summary(forSessionId: sessionId)
    }

    func hasSummary(for sessionId: String) -> Bool {
        loadSummary(for: sessionId) != nil
    }

    nonisolated static func parseSections(from markdown: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = markdown.components(separatedBy: "\n")
        var currentSection: String? = nil
        var currentContent: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let section = currentSection {
                    result[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !currentContent.isEmpty {
                    result["Preamble"] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentContent = []
            } else {
                currentContent.append(line)
            }
        }

        if let section = currentSection {
            result[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }
}
