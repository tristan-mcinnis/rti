import Foundation
import GRDB
import Observation

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

    /// Load any existing notes for the session from the database. Called
    /// when a session begins (start of recording) and when the user
    /// switches to a past session in the detail view.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        notes = Self.loadNotes(forSessionId: sessionId)
    }

    /// Drop the in-memory cursor + cached notes without touching the
    /// database. Use when the active session is unloaded.
    func clear() {
        sessionId = nil
        notes = []
        lastError = nil
        isGenerating = false
    }

    /// Read the persisted notes for an arbitrary session, ordered oldest
    /// first. Used by `reset(for:)` and by tooling that doesn't go
    /// through the singleton's mutable state (e.g. the chat read_notes
    /// tool, session detail view).
    nonisolated static func loadNotes(forSessionId sessionId: String) -> [GeneratedNote] {
        do {
            let rows = try RTIDatabase.shared.pool.read { db in
                try GeneratedNoteRow
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            return rows.map { row in
                GeneratedNote(
                    timestamp: row.createdAt,
                    rangeStartMs: row.rangeStartMs,
                    rangeEndMs: row.rangeEndMs,
                    content: row.content
                )
            }
        } catch {
            RTILog.log("loadNotes failed: \(error)", category: "notes")
            return []
        }
    }

    /// Generate notes for the given transcript window. If `sinceMs` is nil, covers the full transcript.
    /// Returns the `endMs` of the processed transcript on success, so the caller can advance its watermark.
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
            persist(note: note, sessionId: sessionId)
            return result.endMs
        }
    }

    private func persist(note: GeneratedNote, sessionId: String) {
        let row = GeneratedNoteRow(
            id: note.id.uuidString,
            sessionId: sessionId,
            rangeStartMs: note.rangeStartMs,
            rangeEndMs: note.rangeEndMs,
            content: note.content,
            createdAt: note.timestamp
        )
        do {
            try RTIDatabase.shared.pool.write { db in try row.insert(db) }
        } catch {
            RTILog.log("persist generated_note failed: \(error)", category: "notes")
        }
    }
}
