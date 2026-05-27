import Foundation
import Observation

/// Periodically generates structured meeting notes from the live transcript.
/// Ephemeral: notes live in memory for the session and are dropped on
/// `clear()`. The end-of-session `SessionArchive` is responsible for writing
/// the final set to disk — this controller never touches storage.
@Observable @MainActor
final class NotesGenerationController: AnalysisController {
    static let shared = NotesGenerationController()

    private(set) var notes: [GeneratedNote] = []
    var isGenerating = false
    private(set) var lastError: String?

    private let request = LLMRequest()
    private var sessionId: String?

    private static let notesPrompt = """
    You are an AI meeting assistant. Below is the transcript of a meeting conversation.

    Produce structured notes covering what has been discussed. Be thorough but concise. Use markdown formatting.

    ## Key Points
    - List the main points discussed, one per bullet. Be specific; avoid vague labels.

    ## Decisions Made
    - List each decision that was reached, with context for why (if evident). One per bullet.

    ## Action Items
    Only extract items that meet ALL of these criteria:
    - Someone is explicitly named as responsible (skip "we should…" items)
    - A deadline or timeframe was mentioned (skip "soon" / "later")
    - The item was NOT resolved during the meeting itself
    - The item has a concrete deliverable (skip "think about" / "explore")
    List each as: `- [ ] Task description — Owner: @name — Due: date/timeframe`
    If none, write "None."

    ## Open Questions
    - List any open questions raised during the meeting that still need answers.
    If none, write "None."

    Transcript:
    """

    private init() {}

    /// Bind to a session and drop any prior notes.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        notes = []
    }

    func clear() {
        sessionId = nil
        notes = []
        lastError = nil
        isGenerating = false
    }

    /// Generate notes for the given transcript window. If `sinceMs` is nil it
    /// covers the full transcript. Returns the `endMs` of the processed
    /// transcript on success so the scheduler can advance its watermark.
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        return await withGenerationGuard {
            lastError = nil

            guard let result = await TranscriptAnalysis.runText(
                sessionId: sessionId,
                sinceMs: sinceMs,
                smart: true,
                request: request,
                buildPrompt: { Self.notesPrompt + "\n" + $0 }
            ) else {
                lastError = "Notes generation returned empty response."
                return nil
            }

            let note = GeneratedNote(
                timestamp: Date(),
                rangeStartMs: sinceMs ?? 0,
                rangeEndMs: result.endMs,
                content: result.payload
            )
            notes.append(note)
            return result.endMs
        }
    }
}
