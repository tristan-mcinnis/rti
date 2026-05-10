import Foundation

@MainActor
final class NotesGenerationController: ObservableObject {
    static let shared = NotesGenerationController()

    @Published private(set) var notes: [GeneratedNote] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

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

    func reset(for sessionId: String) {
        self.sessionId = sessionId
        notes = []
        lastError = nil
        isGenerating = false
    }

    func clear() {
        sessionId = nil
        notes = []
        lastError = nil
        isGenerating = false
    }

    /// Generate notes for the given transcript window. If `sinceMs` is nil, covers the full transcript.
    /// Returns the `endMs` of the processed transcript on success, so the caller can advance its watermark.
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        guard !isGenerating else { return nil }

        let transcript = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let fullPrompt = Self.notesPrompt + "\n" + trimmed
        let messages = [LLMMessage(role: "user", content: fullPrompt)]

        guard let response = await request.collectAsync(messages: messages, smart: true),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Notes generation returned empty response."
            return nil
        }

        // Compute the endMs watermark from the transcript entries.
        let entries = CorpusBackedStore.transcripts(forSessionId: sessionId)
        let filtered = sinceMs.map { s in entries.filter { $0.startMs >= s } } ?? entries
        let endMs = filtered.last?.startMs ?? entries.last?.startMs ?? 0

        let note = GeneratedNote(
            timestamp: Date(),
            rangeStartMs: sinceMs ?? 0,
            rangeEndMs: endMs,
            content: response
        )
        notes.append(note)
        return endMs
    }
}
