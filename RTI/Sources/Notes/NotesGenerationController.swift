import Foundation
import Observation
import RTICore

/// Periodically generates running meeting notes from the live transcript, one
/// time-block per tick. Ephemeral: notes live in memory for the session and are
/// dropped on `clear()`. The end-of-session `SessionArchive` writes the final
/// set to disk. This controller never touches storage.
@Observable @MainActor
final class NotesGenerationController {
    static let shared = NotesGenerationController()

    private(set) var notes: [GeneratedNote] = []
    var isGenerating = false
    private(set) var lastError: String?
    /// Wall-clock start of the session. Lets the UI show each block's local
    /// time alongside its meeting-relative time.
    private(set) var sessionStartedAt: Date?

    private let request = LLMRequest(priority: .background)
    private var sessionId: String?
    /// Watermark: ms of the last transcript covered by a note. Owned here so the
    /// scheduler tick and the manual "Generate" button both advance the SAME
    /// cursor, otherwise a manual generate re-covers old content and duplicates.
    private var lastNotedMs = 0

    // Prompt default lives in the registry (`PromptID.liveNotes`), resolved
    // through `PromptStore` so it's editable in Settings. The "Transcript slice:"
    // tail is part of the default text.

    /// Bumped on reset/clear so a pass still awaiting the LLM from an older
    /// session cannot write into the new one.
    private var generation = 0
    private init() {}

    /// Bind to a session and drop any prior notes.
    func reset(for sessionId: String) {
        generation += 1
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        notes = []
        lastNotedMs = 0
        sessionStartedAt = SessionCoordinator.shared.startedAt
    }

    func clear() {
        generation += 1
        sessionId = nil
        notes = []
        lastError = nil
        isGenerating = false
        lastNotedMs = 0
        sessionStartedAt = nil
    }

    /// Generate the next note block, covering only transcript since the last
    /// block, and append it. Used by both the periodic scheduler and the manual
    /// "Generate" button; both share `lastNotedMs` so neither duplicates.
    @discardableResult
    func generate(sessionId: String) async -> Int? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        lastError = nil

        let passGeneration = generation
        let windowStartMs = lastNotedMs
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs

        // Nothing new spoken since the last note → skip quietly (no error).
        let window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }
        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? windowStartMs
        RTILog.log("notes: generating from \(window.count) chars (since \(windowStartMs)ms)", category: .notes)

        // Continuity: each tick only sees its 2-minute slice, so feed the
        // previous block back in so the model stops re-introducing people and
        // topics it already noted.
        let priorBlock = notes.last.map { prior in
            "PREVIOUS NOTES BLOCK (already written — context only; do NOT repeat "
                + "or re-introduce these people/points):\n\(prior.content)\n\n"
        } ?? ""
        let prompt = PromptStore.shared.text(.liveNotes) + "\n" + priorBlock + window
        guard let response = await request.collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)], smart: false
        ), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // There WAS transcript to summarize but the model returned nothing.
            // A real failure worth surfacing (don't leave the user guessing).
            lastError = "Couldn't generate notes just now. Will retry."
            RTILog.log("notes: model returned nothing for \(window.count)-char window", category: .notes)
            return nil
        }

        guard passGeneration == generation else { return nil }
        // Advance the watermark even if this block was empty, so we never
        // re-cover the same stretch.
        lastNotedMs = endMs

        let parsed = Self.parse(response)
        guard !parsed.bullets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return endMs }

        notes.append(GeneratedNote(
            timestamp: Date(),
            rangeStartMs: windowStartMs,
            rangeEndMs: endMs,
            title: parsed.title,
            content: parsed.bullets
        ))
        return endMs
    }

    /// Split the model output into its `TITLE:` line and the bullet body.
    /// Falls back to an empty title if the model omitted it.
    static func parse(_ raw: String) -> (title: String, bullets: String) {
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
