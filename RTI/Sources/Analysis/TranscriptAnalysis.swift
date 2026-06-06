import Foundation
import RTICore

/// Shared pipeline for the periodic analyzers (Notes, Dossiers, Discussion
/// Guide matching). Each tick: pull a transcript window → trim → ask the LLM
/// → strip fences → JSON-decode → return payload + watermark. The lines that
/// differ between analyzers are the prompt body, payload type, transcript
/// renderer (timestamped or plain), smart flag, and what to do with the
/// decoded payload — all caller-supplied.
@MainActor
enum TranscriptAnalysis {

    /// Transcript-rendering mode. Plain → `speaker: text` lines. Timestamped
    /// → `[mm:ss] speaker: text` lines (used by analyzers that ask the LLM
    /// to echo timestamps back, e.g. Discussion Guide).
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
    /// all of these as "skip this tick" and leave their watermark unchanged.
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
        guard let (trimmed, endMs) = fetchTranscript(sessionId: sessionId, sinceMs: sinceMs, shape: shape) else { return nil }
        let prompt = buildPrompt(trimmed)
        guard let response = await request.collectAsync(messages: [LLMMessage(role: "user", content: prompt)], smart: smart),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let payload: Payload
        do {
            payload = try JSONExtractor.decode(response, as: Payload.self)
        } catch {
            RTILog.log("TranscriptAnalysis[\(category)] decode failed: \(error)", category: "analysis")
            return nil
        }
        return Result(payload: payload, endMs: endMs)
    }

    /// Same shape as `run`, but for analyzers whose LLM output is
    /// free-form text rather than JSON (e.g. Notes — markdown bullets).
    static func runText(
        sessionId: String,
        sinceMs: Int?,
        shape: TranscriptShape = .plain,
        smart: Bool,
        request: LLMRequest,
        buildPrompt: (_ transcript: String) -> String
    ) async -> Result<String>? {
        guard let (trimmed, endMs) = fetchTranscript(sessionId: sessionId, sinceMs: sinceMs, shape: shape) else { return nil }
        let prompt = buildPrompt(trimmed)
        guard let response = await request.collectAsync(messages: [LLMMessage(role: "user", content: prompt)], smart: smart),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result(payload: response, endMs: endMs)
    }

    // MARK: - Private

    /// Fetch and trim the transcript window. Returns (trimmedTranscript, endMs),
    /// or nil when the window is empty — callers return nil to skip the tick.
    private static func fetchTranscript(
        sessionId: String,
        sinceMs: Int?,
        shape: TranscriptShape
    ) -> (transcript: String, endMs: Int)? {
        let raw: String
        switch shape {
        case .plain:      raw = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        case .timestamped: raw = TranscriptContext.textWithTimestamps(forSessionId: sessionId)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? 0
        return (trimmed, endMs)
    }
}
