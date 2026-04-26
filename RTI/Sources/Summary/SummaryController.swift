import Foundation
import GRDB

@MainActor
final class SummaryController: ObservableObject {
    static let shared = SummaryController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let client: DeepSeekClient
    private var currentTask: Task<Void, Never>?

    private init() {
        self.client = DeepSeekClient(baseURL: Secrets.deepseekBaseURL)
    }

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
        cancel()  // belt-and-suspenders: clear any orphaned task
        isGenerating = true
        lastError = nil

        // Wrap the work in a tracked Task so cancel() can interrupt it. We
        // still await its value so the caller's `await generateSummary(...)`
        // semantics are preserved. The closure must return Void (not ()?) so
        // currentTask's typed Task<Void, Never> matches; weak-self optional-
        // chaining would have made it Task<()?, Never>.
        let task = Task { [weak self] in
            guard let self else { return }
            await self._performGeneration(sessionId: sessionId)
        }
        currentTask = task
        await task.value
        // We're back on MainActor: if cancel() ran during await, it already
        // nilled currentTask and flipped isGenerating. Idempotent reset is
        // safe either way.
        currentTask = nil
        isGenerating = false
    }

    private func _performGeneration(sessionId: String) async {
        let transcript: String
        do {
            transcript = try await RTIDatabase.shared.pool.read { db in
                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)
                return entries.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
            }
        } catch {
            lastError = "Failed to load transcript: \(error)"
            NSLog("[RTI] SummaryController transcript load failed: \(error)")
            return
        }

        if Task.isCancelled { return }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "No transcript content to summarize."
            return
        }

        let fullPrompt = Self.summaryPrompt + "\n" + transcript
        let messages = [DeepSeekMessage(role: "user", content: fullPrompt)]

        var fullResponse = ""
        do {
            for try await delta in client.streamChat(messages: messages, smart: true) {
                if Task.isCancelled { return }
                fullResponse += delta
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            lastError = "Summary generation failed: \(error)"
            NSLog("[RTI] SummaryController stream error: \(error)")
            return
        }

        if Task.isCancelled { return }

        guard !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Summary generation returned empty response."
            return
        }

        let parsed = Self.parseSections(from: fullResponse)
        let responseText = fullResponse
        let combinedFollowUps = Self.combineFollowUps(openQuestions: parsed["Open Questions"], nextSteps: parsed["Next Steps"])

        let summary = SessionSummary(
            id: UUID().uuidString,
            sessionId: sessionId,
            summaryText: responseText,
            actionItems: parsed["Action Items"],
            keyTopics: parsed["Key Topics"],
            decisions: parsed["Decisions Made"],
            followUps: combinedFollowUps,
            rawResponse: responseText,
            createdAt: Date(),
            regeneratedAt: nil
        )

        do {
            try await RTIDatabase.shared.pool.write { db in
                if let existing = try SessionSummary.filter(Column("session_id") == sessionId).fetchOne(db) {
                    var updated = existing
                    updated.summaryText = responseText
                    updated.actionItems = parsed["Action Items"]
                    updated.keyTopics = parsed["Key Topics"]
                    updated.decisions = parsed["Decisions Made"]
                    updated.followUps = combinedFollowUps
                    updated.rawResponse = responseText
                    updated.regeneratedAt = Date()
                    try updated.update(db)
                } else {
                    try summary.insert(db)
                }
            }
        } catch {
            lastError = "Failed to save summary: \(error)"
            NSLog("[RTI] SummaryController save failed: \(error)")
        }
    }

    func loadSummary(for sessionId: String) -> SessionSummary? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try SessionSummary.filter(Column("session_id") == sessionId).fetchOne(db)
            }
        } catch {
            NSLog("[RTI] SummaryController load failed: \(error)")
            return nil
        }
    }

    func hasSummary(for sessionId: String) -> Bool {
        loadSummary(for: sessionId) != nil
    }

    static func parseSections(from markdown: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = markdown.components(separatedBy: "\n")
        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let section = currentSection {
                    result[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
