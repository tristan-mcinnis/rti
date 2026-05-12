import Foundation
import GRDB

/// Owns the active session's discussion guide: parses an imported
/// document into structure, persists it, and periodically asks the LLM
/// to pair unanswered questions with new transcript material.
@MainActor
final class DiscussionGuideController: ObservableObject, AnalysisController {
    static let shared = DiscussionGuideController()

    @Published private(set) var guide: DiscussionGuide?
    @Published private(set) var isImporting = false
    @Published private(set) var isMatching = false
    @Published private(set) var lastError: String?

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
        self.sessionId = sessionId
        lastError = nil
        isMatching = false
        guide = Self.loadRow(sessionId: sessionId)?.guide()
    }

    func clear() {
        sessionId = nil
        guide = nil
        lastError = nil
        isMatching = false
    }

    /// Import a discussion guide from a file (.md, .txt). Reads the
    /// content, calls the parser LLM, persists the structured guide.
    func importGuide(from url: URL, sessionId: String) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let rawText: String
        do {
            rawText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            lastError = "Could not read file: \(error.localizedDescription)"
            return
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Guide file is empty."
            return
        }

        let messages = [LLMMessage(role: "user", content: Self.parsePrompt + "\n" + trimmed)]
        guard let response = await request.collectAsync(messages: messages, smart: true),
              let parsed = Self.parseGuide(response, fileName: url.lastPathComponent) else {
            lastError = "Guide parsing failed — the LLM response wasn't valid JSON."
            return
        }

        let now = Date()
        let row = DiscussionGuideRow(
            sessionId: sessionId,
            fileName: url.lastPathComponent,
            payloadJson: Self.encode(parsed),
            createdAt: now,
            updatedAt: now
        )
        Self.persist(row: row)
        if self.sessionId == sessionId {
            guide = parsed
        }
    }

    /// AnalysisScheduler entry point — match unanswered questions against
    /// the current transcript window. No-op when no guide is loaded.
    @discardableResult
    func match(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        guard !isMatching else { return nil }
        guard var guide else { return nil }
        let unanswered = guide.unansweredQuestions()
        guard !unanswered.isEmpty else { return nil }

        let transcript = TranscriptContext.textWithTimestamps(forSessionId: sessionId)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isMatching = true
        defer { isMatching = false }

        let questionsList = unanswered.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        let prompt = Self.matchPrompt + "\n" + questionsList + "\n\nTranscript window (with [mm:ss] timestamps):\n" + trimmed
        let messages = [LLMMessage(role: "user", content: prompt)]
        guard let response = await request.collectAsync(messages: messages, smart: false),
              let matches = Self.parseMatches(response) else {
            return nil
        }
        guard !matches.isEmpty else { return nil }

        guide.apply(matches: matches)
        if self.sessionId == sessionId {
            self.guide = guide
        }
        let now = Date()
        let row = DiscussionGuideRow(
            sessionId: sessionId,
            fileName: guide.fileName,
            payloadJson: Self.encode(guide),
            createdAt: now,
            updatedAt: now
        )
        Self.persistMatched(row: row)
        return TranscriptContext.watermarkEndMs(forSessionId: sessionId)
    }

    /// Satisfies `AnalysisController`. Delegates to `match` so the
    /// scheduler can drive this controller the same way it drives Notes,
    /// Dossiers, and Themes.
    @discardableResult
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        await match(sessionId: sessionId, sinceMs: sinceMs)
    }

    /// Drop the guide for the active session.
    func removeGuide(for sessionId: String) {
        do {
            _ = try RTIDatabase.shared.pool.write { db in
                try DiscussionGuideRow.deleteOne(db, key: sessionId)
            }
        } catch {
            NSLog("[RTI] DiscussionGuideController removeGuide failed: \(error)")
        }
        if self.sessionId == sessionId {
            guide = nil
        }
    }

    // MARK: - Parsing

    private static func parseGuide(_ raw: String, fileName: String) -> DiscussionGuide? {
        guard let data = stripFences(raw).data(using: .utf8) else { return nil }
        struct Parsed: Decodable { let objectives: [GuideObjective] }
        let decoder = JSONDecoder()
        guard let p = try? decoder.decode(Parsed.self, from: data), !p.objectives.isEmpty else { return nil }
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

    private static func parseMatches(_ raw: String) -> [GuideMatch]? {
        guard let data = stripFences(raw).data(using: .utf8) else { return nil }
        struct Wrapper: Decodable { let matches: [GuideMatch] }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.matches
    }

    private static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    private static func encode(_ guide: DiscussionGuide) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(guide),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"objectives\":[]}"
        }
        return str
    }

    // MARK: - Persistence

    nonisolated private static func persist(row: DiscussionGuideRow) {
        do {
            try RTIDatabase.shared.pool.write { db in try row.save(db) }
        } catch {
            NSLog("[RTI] DiscussionGuide persist failed: \(error)")
        }
    }

    nonisolated private static func persistMatched(row: DiscussionGuideRow) {
        persist(row: row)
    }

    nonisolated static func loadRow(sessionId: String) -> DiscussionGuideRow? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try DiscussionGuideRow
                    .filter(Column("session_id") == sessionId)
                    .fetchOne(db)
            }
        } catch {
            NSLog("[RTI] DiscussionGuide load failed: \(error)")
            return nil
        }
    }
}
