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

    // MARK: - Parsing prompts

    private static let parsePrompt = """
    You convert a raw moderated-interview discussion guide into a structured JSON outline. Output ONLY JSON.

    Shape:
    {
      "objectives": [
        {
          "id": "obj_1",
          "title": "Objective title",
          "description": "Optional short description, or null.",
          "sections": [
            {
              "id": "obj_1_sec_1",
              "title": "Section title",
              "questions": [
                { "id": "obj_1_sec_1_q1", "text": "Question text" }
              ]
            }
          ]
        }
      ]
    }

    Rules:
    - Preserve the author's wording for question text — do not paraphrase.
    - Use stable, hierarchical IDs as shown.
    - If the document has no explicit objective grouping, create a single objective titled "Discussion guide" containing all sections.
    - If the document has no section grouping, create a single section titled the same as its parent objective.
    - Skip preamble, methodology notes, and timing instructions that aren't questions.
    - Output JSON only — no markdown fences, no commentary.

    Raw guide document:
    """

    private static let matchPrompt = """
    You match unanswered questions from a discussion guide against the live transcript window. Output ONLY JSON.

    Shape:
    {
      "matches": [
        {
          "questionId": "obj_1_sec_1_q1",
          "summary": "One-line summary of what the participant said.",
          "quotes": [
            { "text": "Verbatim quote.", "speaker": "self|them_1|…", "timestampMs": 123456 }
          ],
          "confidence": "high|medium|low",
          "status": "partial|answered"
        }
      ]
    }

    Rules:
    - Only emit a match when the transcript clearly addresses the question. Skip questions that have not been touched.
    - Quote text MUST be verbatim from the transcript.
    - Compute timestampMs from the `[mm:ss]` prefix (mm*60000 + ss*1000).
    - status = "answered" only when the response is substantive and complete; otherwise "partial".
    - confidence = "high" only when the quote leaves no ambiguity.
    - Output JSON only.

    Unanswered questions:
    """

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

    /// Read a guide file (.md/.txt) and parse it into a pending preview. Works
    /// with or without an active session — the guide is only *committed* on
    /// `confirmPending()`. Falls back from UTF-8 to the file's own encoding so
    /// the odd non-UTF-8 export still reads.
    func loadFile(from url: URL) async {
        let raw: String
        do {
            raw = try Self.readText(url)
        } catch {
            lastError = "Could not read file: \(error.localizedDescription)"
            return
        }
        await parse(text: raw, fileName: url.lastPathComponent)
    }

    /// Parse raw guide text (pasted or read from a file) into a pending preview.
    /// The LLM normalises whatever formatting the source had into structure.
    func parse(text: String, fileName: String) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Nothing to parse."
            return
        }

        let messages = [LLMMessage(role: "user", content: Self.parsePrompt + "\n" + trimmed)]
        guard let response = await request.collectAsync(messages: messages, smart: true),
              let parsed = Self.parseGuide(response, fileName: fileName) else {
            lastError = "Couldn't turn that into a guide. Try a cleaner paste or a different file."
            return
        }

        pendingGuide = parsed
        lastError = nil
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
    /// Shares the fetch → LLM → strip → decode pipeline with Notes and
    /// Dossiers via `TranscriptAnalysis.run` (timestamped shape, so the model
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

        let questionsList = unanswered.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        guard let result = await TranscriptAnalysis.run(
            sessionId: sessionId,
            sinceMs: sinceMs,
            shape: .timestamped,
            smart: false,
            request: request,
            category: "discussionGuide",
            as: GuideMatchResponse.self,
            buildPrompt: {
                Self.matchPrompt + "\n" + questionsList
                    + "\n\nTranscript window (with [mm:ss] timestamps):\n" + $0
            }
        ) else { return nil }

        guard !result.payload.matches.isEmpty else { return nil }

        guide.apply(matches: result.payload.matches)
        if self.sessionId == sessionId {
            self.guide = guide
        }
        return result.endMs
    }

    // MARK: - Parsing

    /// Read a text file as UTF-8, falling back to its detected encoding.
    private static func readText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        var used: String.Encoding = .utf8
        return try String(contentsOf: url, usedEncoding: &used)
    }

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

/// Wire shape for the matcher's JSON response: `{ "matches": [GuideMatch] }`.
/// Decoded by `TranscriptAnalysis.run`.
private struct GuideMatchResponse: Decodable {
    let matches: [GuideMatch]
}
