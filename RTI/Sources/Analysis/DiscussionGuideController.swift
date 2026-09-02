import Foundation
import Observation
import RTICore

/// Owns the active session's discussion guide: parses an imported document
/// into structure and periodically asks the LLM to pair unanswered questions
/// with new transcript material. Ephemeral — the guide lives in memory only;
/// the end-of-session `SessionArchive` writes the final state.
@Observable @MainActor
final class DiscussionGuideController {
    static let shared = DiscussionGuideController()

    private(set) var guide: DiscussionGuide?
    /// A freshly parsed guide awaiting the user's confirmation in the Setup
    /// tab. Lets us show the parsed structure ("does this look right?") before
    /// it becomes the active guide — the safety net for messy input.
    private(set) var pendingGuide: DiscussionGuide?
    private(set) var isImporting = false
    private(set) var isMatching = false
    private(set) var lastError: String?

    private let request = LLMRequest()
    private var sessionId: String?

    // Parsing prompts: defaults live in the registry (`PromptID.dgParse`,
    // `PromptID.dgMatch`), resolved through `PromptStore` so they're editable in
    // Settings. The "Raw guide document:" / "Unanswered questions…:" tails are
    // part of those default strings.

    private init() {}

    // MARK: - Public API

    func reset(for sessionId: String) {
        lastError = nil
        isMatching = false
        // Preserve a guide staged before the call (confirmed while no session was
        // running → sessionId == nil) and bind it to this fresh session. Drop a
        // guide that belonged to a previous, now-ended session.
        let staged = guide != nil && self.sessionId == nil
        self.sessionId = sessionId
        if !staged { guide = nil }
    }

    func clear() {
        sessionId = nil
        guide = nil
        pendingGuide = nil
        lastError = nil
        isMatching = false
    }

    // MARK: - Loading (pre-call or live)

    /// Read a guide file (any of .md/.txt/.docx/.doc/.pdf/.rtf/.html) and parse
    /// it into a pending preview. Works with or without an active session — the
    /// guide is only *committed* on `confirmPending()`. Format extraction lives
    /// in `GuideTextExtractor`; structure parsing in `parse(text:)`.
    func loadFile(from url: URL) async {
        let raw: String
        do {
            raw = try GuideTextExtractor.text(from: url)
        } catch {
            lastError = "Could not read file: \(error.localizedDescription)"
            RTILog.log("guide: extract failed for \(url.lastPathComponent): \(error.localizedDescription)", category: .guide)
            return
        }
        await parse(text: raw, fileName: url.lastPathComponent)
    }

    /// Parse raw guide text (pasted or extracted from a file) into a pending
    /// preview. Deterministic-first: the IC house format is parsed directly with
    /// no model call; only genuinely unstructured input falls back to the LLM
    /// normaliser. Either way the preview gates commit, so the user sees what
    /// was parsed before it goes live.
    func parse(text: String, fileName: String) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Nothing to parse."
            return
        }

        // 1) Deterministic house-format parse — instant, offline, lossless.
        if let objectives = GuideParser.parse(trimmed) {
            let questionCount = objectives.reduce(0) { $0 + $1.sections.reduce(0) { $0 + $1.questions.count } }
            pendingGuide = DiscussionGuide(
                id: UUID().uuidString,
                fileName: fileName,
                parsedAt: Date(),
                objectives: objectives
            )
            lastError = nil
            RTILog.log("guide: parsed deterministically — \(objectives.count) objectives, \(questionCount) questions", category: .guide)
            return
        }

        // 2) Fallback: LLM normalisation for messy / non-house-format input.
        RTILog.log("guide: no house structure detected, falling back to LLM parse", category: .guide)
        guard let parsed = await llmParse(trimmed, fileName: fileName) else {
            lastError = "Couldn't turn that into a guide. Try a cleaner paste or a different file."
            return
        }
        pendingGuide = parsed
        lastError = nil
    }

    /// LLM fallback parser with one repair retry. Logs the raw model output on
    /// failure so a bad parse is diagnosable instead of a blind red line.
    private func llmParse(_ text: String, fileName: String) async -> DiscussionGuide? {
        let base = [LLMMessage(role: "user", content: PromptStore.shared.text(.dgParse) + "\n" + text)]
        guard let response = await request.collectAsync(messages: base, smart: true) else {
            RTILog.log("guide: LLM parse returned no response", category: .guide)
            return nil
        }
        if let guide = Self.parseGuide(response, fileName: fileName) { return guide }

        // Models sometimes wrap JSON in prose or emit trailing commas — one
        // targeted repair pass recovers most of those.
        RTILog.log("guide: LLM JSON invalid, retrying once. Raw head: \(response.prefix(240))", category: .guide)
        let repair = base + [
            LLMMessage(role: "assistant", content: response),
            LLMMessage(role: "user", content: "That was not valid JSON in the required shape. Output ONLY the JSON object — no prose, no markdown fences."),
        ]
        guard let retry = await request.collectAsync(messages: repair, smart: true),
              let guide = Self.parseGuide(retry, fileName: fileName)
        else {
            RTILog.log("guide: LLM parse failed after repair retry", category: .guide)
            return nil
        }
        return guide
    }

    /// Commit the pending preview as the active guide. Binds it to the running
    /// session if there is one; otherwise leaves it staged (sessionId == nil) so
    /// the next session picks it up via `reset(for:)`.
    func confirmPending() {
        guard let pending = pendingGuide else { return }
        guide = pending
        pendingGuide = nil
        let coordinator = SessionCoordinator.shared
        sessionId = coordinator.isRunning ? coordinator.currentSessionId : nil
    }

    /// Discard the pending preview without committing it.
    func discardPending() {
        pendingGuide = nil
        lastError = nil
    }

    /// Drop the active guide (and any pending preview). Usable pre-call or live.
    func remove() {
        guide = nil
        pendingGuide = nil
        lastError = nil
    }

    /// AnalysisScheduler entry point — match unanswered questions against
    /// the current transcript window. No-op when no guide is loaded.
    ///
    /// Shares the fetch → LLM → strip → decode pipeline with Notes
    /// via `TranscriptAnalysis.run` (timestamped shape, so the model
    /// can echo `[mm:ss]` into its quotes). The guide-specific work — building
    /// the unanswered-questions list and folding matches back into the guide —
    /// stays here.
    @discardableResult
    func match(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        guard !isMatching else { return nil }
        guard var guide else { return nil }
        let unanswered = guide.unansweredQuestions()
        guard !unanswered.isEmpty else { return nil }

        isMatching = true
        defer { isMatching = false }

        // One line per question — flatten the EN/中文 newline so each stays a
        // single "- [id] EN / 中文" row the model can key by id cleanly.
        let questionsList = unanswered.map { q in
            "- [\(q.id)] " + q.text.replacingOccurrences(of: "\n", with: " / ")
        }.joined(separator: "\n")
        RTILog.log("guide: matching \(unanswered.count) unanswered questions", category: .guide)

        // Resolve on the actor; the closure may run off the main actor.
        let matchPrompt = PromptStore.shared.text(.dgMatch)
        guard let result = await TranscriptAnalysis.runLenientArray(
            sessionId: sessionId,
            sinceMs: sinceMs,
            shape: .timestamped,
            smart: false,
            request: request,
            category: "discussionGuide",
            key: "matches",
            as: GuideMatch.self,
            buildPrompt: {
                matchPrompt + "\n" + questionsList
                    + "\n\nTranscript window (with [mm:ss] timestamps):\n" + $0
            }
        ) else {
            RTILog.log("guide: matcher got no result (empty transcript or LLM/parse failure)", category: .guide)
            return nil
        }

        let returned = result.payload
        let allIds = Set(guide.objectives.flatMap { $0.sections.flatMap { $0.questions.map(\.id) } })
        let validCount = returned.count(where: { allIds.contains($0.questionId) })
        RTILog.log("guide: LLM returned \(returned.count) matches, \(validCount) map to known ids", category: .guide)
        if returned.count > 0, validCount == 0 {
            let sample = returned.prefix(3).map(\.questionId).joined(separator: ", ")
            RTILog.log("guide: NONE matched known ids — returned ids e.g. [\(sample)]", category: .guide)
        }

        guard !returned.isEmpty else { return nil }

        guide.apply(matches: returned)
        if self.sessionId == sessionId {
            self.guide = guide
        }
        return result.endMs
    }

    // MARK: - Parsing

    private static func parseGuide(_ raw: String, fileName: String) -> DiscussionGuide? {
        struct Parsed: Decodable { let objectives: [GuideObjective] }
        guard let p = JSONExtractor.tryDecode(raw, as: Parsed.self), !p.objectives.isEmpty else { return nil }
        // Force all questions to start pending — the matcher will move
        // them to partial/answered as evidence comes in.
        let stripped: [GuideObjective] = p.objectives.map { obj in
            GuideObjective(
                id: obj.id,
                title: obj.title,
                description: obj.description,
                sections: obj.sections.map { sec in
                    GuideSection(
                        id: sec.id,
                        title: sec.title,
                        questions: sec.questions.map { q in
                            GuideQuestion(id: q.id, text: q.text, status: .pending, response: nil)
                        }
                    )
                },
                takeaway: nil
            )
        }
        return DiscussionGuide(
            id: UUID().uuidString,
            fileName: fileName,
            parsedAt: Date(),
            objectives: stripped
        )
    }
}
