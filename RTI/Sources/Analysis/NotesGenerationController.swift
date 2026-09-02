import Foundation
import Observation

/// Periodically generates running meeting notes from the live transcript, one
/// time-block per tick. Ephemeral: notes live in memory for the session and are
/// dropped on `clear()`. The end-of-session `SessionArchive` writes the final
/// set to disk — this controller never touches storage.
@Observable @MainActor
final class NotesGenerationController {
    static let shared = NotesGenerationController()

    private(set) var notes: [GeneratedNote] = []
    var isGenerating = false
    private(set) var lastError: String?
    /// Wall-clock start of the session — lets the UI show each block's local
    /// time alongside its meeting-relative time.
    private(set) var sessionStartedAt: Date?

    private let request = LLMRequest()
    private var sessionId: String?
    /// Watermark: ms of the last transcript covered by a note. Owned here so the
    /// scheduler tick and the manual "Generate" button both advance the SAME
    /// cursor — otherwise a manual generate re-covers old content and duplicates.
    private var lastNotedMs = 0

    // Prompt default lives in the registry (`PromptID.liveNotes`), resolved
    // through `PromptStore` so it's editable in Settings. The "Transcript slice:"
    // tail is part of the default text.

    private init() {}

    /// Bind to a session and drop any prior notes.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        notes = []
        lastNotedMs = 0
        sessionStartedAt = SessionCoordinator.shared.startedAt
    }

    func clear() {
        sessionId = nil
        notes = []
        lastError = nil
        isGenerating = false
        lastNotedMs = 0
        sessionStartedAt = nil
    }

    /// Generate the next note block — covering only transcript since the last
    /// block — and append it. Used by both the periodic scheduler and the manual
    /// "Generate" button; both share `lastNotedMs` so neither duplicates.
    @discardableResult
    func generate(sessionId: String) async -> Int? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        lastError = nil

        let windowStartMs = lastNotedMs
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs

        // Nothing new spoken since the last note → skip quietly (no error).
        let window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        guard !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        RTILog.log("notes: generating from \(window.count) chars (since \(windowStartMs)ms)", category: .notes)

        // Continuity: each tick only sees its 2-minute slice, so feed the
        // previous block back in — the model stops re-introducing people and
        // topics it already noted.
        let priorBlock = notes.last.map { prior in
            "PREVIOUS NOTES BLOCK (already written — context only; do NOT repeat "
                + "or re-introduce these people/points):\n\(prior.content)\n\n"
        } ?? ""
        // Resolve on the actor; the closure may run off the main actor.
        let notesPrompt = PromptStore.shared.text(.liveNotes)
        guard let result = await TranscriptAnalysis.runText(
            sessionId: sessionId,
            sinceMs: sinceMs,
            smart: false,
            request: request,
            buildPrompt: { notesPrompt + "\n" + priorBlock + $0 }
        ) else {
            // There WAS transcript to summarize but the model returned nothing —
            // a real failure worth surfacing (don't leave the user guessing).
            lastError = "Couldn't generate notes just now — will retry."
            RTILog.log("notes: model returned nothing for \(window.count)-char window", category: .notes)
            return nil
        }

        // Advance the watermark even if this block was empty, so we never
        // re-cover the same stretch.
        lastNotedMs = result.endMs

        let parsed = Self.parse(result.payload)
        guard !parsed.bullets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result.endMs }

        notes.append(GeneratedNote(
            timestamp: Date(),
            rangeStartMs: windowStartMs,
            rangeEndMs: result.endMs,
            title: parsed.title,
            content: parsed.bullets
        ))
        return result.endMs
    }

    /// Split the model output into its `TITLE:` line and the bullet body.
    /// Falls back to an empty title if the model omitted it.
    private static func parse(_ raw: String) -> (title: String, bullets: String) {
        var title = ""
        var bullets: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if title.isEmpty, trimmed.uppercased().hasPrefix("TITLE:") {
                title = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " :-"))
            } else if !trimmed.isEmpty {
                bullets.append(line)
            }
        }
        return (title, bullets.joined(separator: "\n"))
    }
}
