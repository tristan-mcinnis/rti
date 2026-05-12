import Foundation

/// Shared pipeline for the periodic analyzers (Notes, Dossiers, Themes).
/// Each tick: pull a transcript window → trim → ask the LLM → strip fences
/// → JSON-decode → return payload + watermark. The five lines that
/// differ between analyzers are the prompt body, payload type, transcript
/// renderer (timestamped or plain), smart flag, and what to do with the
/// decoded payload — all caller-supplied.
///
/// Result handling (merge vs append vs overwrite) and persistence stay
/// with each controller, since those genuinely vary. The duplication this
/// kills is the lifecycle scaffolding: gating, empty-window guard, fence
/// stripping, JSON decode, error logging, watermark math.
@MainActor
enum TranscriptAnalysis {

    /// Transcript-rendering mode. Plain → `speaker: text` lines. Timestamped
    /// → `[mm:ss] speaker: text` lines (used by analyzers that ask the LLM
    /// to echo timestamps back, e.g. Themes, Discussion Guide).
    enum TranscriptShape {
        case plain
        case timestamped
    }

    struct Result<Payload> {
        let payload: Payload
        let endMs: Int
    }

    /// Run a single analysis pass. Returns nil on empty transcript, empty
    /// LLM response, parse failure, or cancellation — callers should treat
    /// all of these as "skip this tick" and leave their watermark
    /// unchanged.
    ///
    /// `category` is the RTILog category for the diagnostic line emitted on
    /// parse failure. Each analyzer passes its own ("notes", "dossiers",
    /// "themes") so the log preserves a way to track which one drifted.
    static func run<Payload: Decodable>(
        sessionId: String,
        sinceMs: Int?,
        shape: TranscriptShape = .plain,
        smart: Bool,
        request: LLMRequest,
        category: String,
        as type: Payload.Type = Payload.self,
        buildPrompt: (_ transcript: String) -> String
    ) async -> Result<Payload>? {
        let transcript: String
        switch shape {
        case .plain:
            transcript = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        case .timestamped:
            transcript = TranscriptContext.textWithTimestamps(forSessionId: sessionId)
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prompt = buildPrompt(trimmed)
        let messages = [LLMMessage(role: "user", content: prompt)]

        guard let response = await request.collectAsync(messages: messages, smart: smart),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let payload: Payload
        do {
            payload = try JSONExtractor.decode(response, as: Payload.self)
        } catch {
            NSLog("[RTI] TranscriptAnalysis[\(category)] decode failed: \(error)")
            return nil
        }

        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? 0
        return Result(payload: payload, endMs: endMs)
    }

    /// Same shape as `run`, but for analyzers whose LLM output is
    /// free-form text rather than JSON (e.g. Notes — markdown bullets).
    /// Returns the trimmed response and watermark; caller persists.
    static func runText(
        sessionId: String,
        sinceMs: Int?,
        shape: TranscriptShape = .plain,
        smart: Bool,
        request: LLMRequest,
        buildPrompt: (_ transcript: String) -> String
    ) async -> Result<String>? {
        let transcript: String
        switch shape {
        case .plain:
            transcript = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        case .timestamped:
            transcript = TranscriptContext.textWithTimestamps(forSessionId: sessionId)
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prompt = buildPrompt(trimmed)
        let messages = [LLMMessage(role: "user", content: prompt)]

        guard let response = await request.collectAsync(messages: messages, smart: smart),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? 0
        return Result(payload: response, endMs: endMs)
    }
}
