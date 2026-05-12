import Foundation
import GRDB

/// Periodically scans the live transcript for emergent topics + their
/// verbatim, speaker- and timestamp-attributed quotes. Mirrors the shape
/// of `NotesGenerationController` and `DossierController` so it slots
/// into `AnalysisScheduler` the same way.
///
/// Storage is one row per session in `session_themes`. Each tick
/// overwrites that row with the latest payload (real-time updates
/// replace, they don't accumulate). On session end, a final hi-fi pass
/// runs against the full transcript and overwrites once more with
/// `is_hi_fi = 1` set on the row.
@MainActor
final class ThemesController: ObservableObject {
    static let shared = ThemesController()

    @Published private(set) var payload: ThemesPayload = .empty
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var isHiFi = false
    @Published private(set) var generatedAt: Date?

    private let request = LLMRequest()
    private var sessionId: String?

    // Real-time pass: tight prompt, aim for 3–6 topics, fast LLM model.
    private static let realtimePrompt = """
    You are watching a live conversation transcript and grouping it by topic so the user can scan it later.

    Output ONLY a JSON object with this shape:

    {
      "themes": [
        {
          "title": "Short, specific topic title (3–6 words)",
          "summary": "One sentence describing the topic. Optional, omit if redundant with the title.",
          "quotes": [
            { "speaker": "self", "timestampMs": 12345, "text": "Verbatim quote from the transcript." }
          ]
        }
      ]
    }

    Rules:
    - Quote text MUST be verbatim from the transcript — do not paraphrase.
    - Use the `[mm:ss]` timestamps to compute `timestampMs` (mm*60000 + ss*1000).
    - Use the speaker label as written ("self", "them_1", "them_2", etc.).
    - Aim for 3–6 distinct topics. Skip filler chitchat.
    - Prefer specific titles ("Impact of offline retail in tier-2 cities") over generic ones ("Retail").
    - 2–6 quotes per topic; pick the ones that best illustrate it.
    - Quote text and topic titles in the language of the conversation.
    - Output JSON only. No markdown fences, no commentary.

    Transcript (with [mm:ss] timestamps):
    """

    // Hi-fi pass: same shape, but invites a tighter, more curated
    // post-session summary. 4–10 topics, longer quotes allowed.
    private static let hiFiPrompt = """
    The conversation has ended. Produce a final, curated themes-and-quotes view of the entire transcript.

    Same JSON shape as the live view:

    {
      "themes": [
        {
          "title": "Short, specific topic title (3–6 words)",
          "summary": "One sentence describing the topic.",
          "quotes": [
            { "speaker": "self", "timestampMs": 12345, "text": "Verbatim quote." }
          ]
        }
      ]
    }

    Rules:
    - Quote text MUST be verbatim from the transcript.
    - Compute `timestampMs` from the `[mm:ss]` prefix.
    - 4–10 distinct topics, ordered by significance to the conversation.
    - 3–8 quotes per topic.
    - Topic titles should be specific and quotable.
    - Output JSON only.

    Full transcript (with [mm:ss] timestamps):
    """

    private init() {}

    /// Bind the controller to a session — loads the persisted themes row
    /// if there is one.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        let row = Self.loadRow(sessionId: sessionId)
        payload = row?.payload() ?? .empty
        isHiFi = row?.isHiFi ?? false
        generatedAt = row?.generatedAt
    }

    /// Drop in-memory state without touching the DB. Mirrors the existing
    /// notes/dossier `clear()` semantics.
    func clear() {
        sessionId = nil
        payload = .empty
        isHiFi = false
        generatedAt = nil
        lastError = nil
        isGenerating = false
    }

    /// AnalysisScheduler entry point. Re-runs the periodic prompt against
    /// the full transcript-so-far. `sinceMs` is ignored — themes are
    /// regenerated from scratch each pass because previous quotes might
    /// regroup under new topics.
    @discardableResult
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        await run(sessionId: sessionId, hiFi: false)
    }

    /// Final post-session pass. Idempotent — calling it twice produces
    /// two final-shape outputs, but the second overwrites the first.
    func generateHiFi(sessionId: String) async {
        _ = await run(sessionId: sessionId, hiFi: true)
    }

    private func run(sessionId: String, hiFi: Bool) async -> Int? {
        guard !isGenerating else { return nil }
        let transcript = TranscriptContext.textWithTimestamps(forSessionId: sessionId)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let prompt = (hiFi ? Self.hiFiPrompt : Self.realtimePrompt) + "\n" + trimmed
        let messages = [LLMMessage(role: "user", content: prompt)]

        guard let response = await request.collectAsync(messages: messages, smart: hiFi),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Themes generation returned empty response."
            return nil
        }

        guard let parsed = Self.parsePayload(response) else {
            lastError = "Themes JSON could not be parsed."
            return nil
        }

        // Persist + publish only if we actually got at least one topic.
        guard !parsed.themes.isEmpty else { return nil }

        let now = Date()
        let json: Data
        do {
            json = try JSONEncoder().encode(parsed)
        } catch {
            NSLog("[RTI] ThemesController encode failed: \(error)")
            return nil
        }
        let row = SessionThemesRow(
            sessionId: sessionId,
            payloadJson: String(data: json, encoding: .utf8) ?? "{\"themes\":[]}",
            generatedAt: now,
            isHiFi: hiFi
        )
        Self.persist(row: row)

        // Only mutate the published state if we're still on the same
        // session — the user might have switched away while the request
        // was in flight.
        if self.sessionId == sessionId {
            payload = parsed
            isHiFi = hiFi
            generatedAt = now
        }
        return TranscriptContext.watermarkEndMs(forSessionId: sessionId)
    }

    private static func parsePayload(_ raw: String) -> ThemesPayload? {
        // The model occasionally wraps JSON in ```json fences despite the
        // prompt; strip them defensively.
        let stripped: String = {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                if let firstNewline = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: firstNewline)...])
                }
                if s.hasSuffix("```") {
                    s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return s
        }()
        guard let data = stripped.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ThemesPayload.self, from: data)
    }

    /// Synchronous write helper. Pulled out of the async `run` method so
    /// Swift picks the blocking GRDB overload rather than the async one,
    /// matching the pattern used by `NotesGenerationController.persist`.
    nonisolated private static func persist(row: SessionThemesRow) {
        do {
            try RTIDatabase.shared.pool.write { db in try row.save(db) }
        } catch {
            NSLog("[RTI] ThemesController persist failed: \(error)")
        }
    }

    /// Read the persisted themes row for an arbitrary session. Used by
    /// the session detail view and the panel's `reset(for:)`.
    nonisolated static func loadRow(sessionId: String) -> SessionThemesRow? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try SessionThemesRow
                    .filter(Column("session_id") == sessionId)
                    .fetchOne(db)
            }
        } catch {
            NSLog("[RTI] ThemesController load failed: \(error)")
            return nil
        }
    }
}
