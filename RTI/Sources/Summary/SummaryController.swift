import Foundation

@MainActor
final class SummaryController: ObservableObject {
    static let shared = SummaryController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let client = DeepSeekClient.shared
    private var currentTask: Task<Void, Never>?
    /// Per-session in-memory cache. Keyed by session id, populated on
    /// generation, consumed by `CorpusManager.renderSession` at session-end
    /// and by `CorpusBackedStore.summary(forSessionId:)` while a session is
    /// in-flight. Markdown becomes the durable record once written; the
    /// cache is purged after a successful render.
    private var cache: [String: SessionSummary] = [:]

    private init() {}

    /// Cancel an in-flight summary generation. Safe to call when nothing is
    /// running. Flips isGenerating immediately so the UI returns to its
    /// empty state without waiting for the URLSession to unwind.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    private static let summaryPrompt = """
    You are an AI meeting assistant. Below is the full transcript of a meeting conversation.

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

    func generateSummary(for sessionId: String) async {
        guard !isGenerating else { return }
        cancel()
        isGenerating = true
        lastError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            await self._performGeneration(sessionId: sessionId)
        }
        currentTask = task
        await task.value
        currentTask = nil
        isGenerating = false
    }

    private func _performGeneration(sessionId: String) async {
        let transcript = TranscriptContext.text(forSessionId: sessionId)
        if Task.isCancelled { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "No transcript content to summarize."
            return
        }

        let fullPrompt = Self.summaryPrompt + "\n" + transcript
        let messages = [DeepSeekMessage(role: "user", content: fullPrompt)]

        let fullResponse: String
        do {
            fullResponse = try await client.collectStreamedResponse(messages: messages, smart: true)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            lastError = (error as? DeepSeekError)?.userMessage ?? "Summary generation failed: \(error)"
            NSLog("[RTI] SummaryController stream error: \(error)")
            return
        }

        if Task.isCancelled { return }

        guard !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Summary generation returned empty response."
            return
        }

        let parsed = Self.parseSections(from: fullResponse)
        let combinedFollowUps = Self.combineFollowUps(openQuestions: parsed["Open Questions"], nextSteps: parsed["Next Steps"])

        cache[sessionId] = SessionSummary(
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

    static func parseSections(from markdown: String) -> [String: String] {
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

    private static func combineFollowUps(openQuestions: String?, nextSteps: String?) -> String? {
        var parts: [String] = []
        if let q = openQuestions, q != "None.", !q.isEmpty {
            parts.append("## Open Questions\n\(q)")
        }
        if let s = nextSteps, s != "None.", !s.isEmpty {
            parts.append("## Next Steps\n\(s)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
