import Foundation
import Observation

/// Per-session Q&A — answers questions about a single session's
/// transcript + summary. Subclasses `CorpusChatController` so the
/// streaming lifecycle, citation handling, prior-turn windowing, and
/// message state live in one place across all three Q&A surfaces (this,
/// `AskCorpusController`, `ProjectQAController`).
///
/// Retrieval here returns a single candidate — the session itself — so
/// `[Session Title]` citations still work if the user asks the model to
/// quote. The system prompt injects the full transcript + summary
/// directly (rather than the base truncated-summary context) because at
/// single-session scope we want the model to see every word.
@MainActor
final class SessionQAController: CorpusChatController {
    static let shared = SessionQAController()

    private var currentSessionId: String?

    /// Compatibility alias for the prior API. Sets the active session and
    /// kicks off `ask(question:)` on the base controller.
    func ask(question: String, sessionId: String) {
        currentSessionId = sessionId
        ask(question: question)
    }

    /// Kept for parity with the prior surface — callers used `clear()` to
    /// reset chat state. Maps onto `newChat()` in the base.
    func clear() { newChat() }

    // MARK: - Strategy

    override func retrieve(forQuestion question: String) throws -> [CorpusChatCandidate] {
        guard let id = currentSessionId,
              let session = CorpusBackedStore.session(id: id) else {
            throw CorpusChatError(message: "No transcript or summary available for this session.")
        }
        let transcript = TranscriptContext.text(forSessionId: id)
        let summary = CorpusBackedStore.summary(forSessionId: id)?.summaryText
        if transcript.isEmpty && (summary?.isEmpty ?? true) {
            throw CorpusChatError(message: "No transcript or summary available for this session.")
        }
        return [CorpusChatCandidate(
            session: session,
            title: Self.displayTitle(for: session),
            snippet: nil,
            summary: nil
        )]
    }

    override func makeSystemPrompt(context: String) -> String {
        let id = currentSessionId ?? ""
        let body = buildSessionContext(sessionId: id)
        return """
        You are RTI, the user's meeting assistant. Answer questions based ONLY on the provided session transcript and summary below.
        If the answer isn't in the transcript, say so briefly. Be concise and helpful.

        If the context contains a "## User notes" block, treat those notes as authoritative corrections
        from the user (e.g. name spellings, identity clarifications, factual fixes). Prefer them over
        anything in the raw transcript.

        Session context:
        \(body)
        """
    }

    private func buildSessionContext(sessionId: String) -> String {
        var parts: [String] = []
        if let summary = CorpusBackedStore.summary(forSessionId: sessionId) {
            parts.append("## Meeting Summary")
            parts.append(summary.summaryText)
        }
        let transcript = TranscriptContext.text(forSessionId: sessionId)
        if !transcript.isEmpty {
            parts.append("## Full Transcript")
            parts.append(transcript)
        }
        return parts.joined(separator: "\n\n")
    }
}
