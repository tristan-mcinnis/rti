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

    private static let notesPrompt = """
    You are taking live meeting notes — jotting points down as they are said.

    LANGUAGE: Write the notes in ENGLISH. The conversation may be in Chinese or
    another language; translate as you go. You MAY keep a short essential term in
    its original language in parentheses when the English alone loses meaning —
    e.g. "fear of looking identical (撞衫)", "chest pads (胸垫)". Do NOT write whole
    bullets in Chinese. Keep people's names and brand names as spoken.

    For this slice of the conversation, produce:
    1. A first line `TITLE: <a short 3–6 word title for what this slice covered>`.
    2. Then a flat list of concise note bullets — facts, opinions, preferences,
       choices, questions — in the order they came up.

    Format EXACTLY:
    TITLE: <short title>
    - <bullet>
    - <bullet>

    Rules:
    - Be specific and concrete, e.g. "- Favourite brand is Brandco, but can't find a store in Shanghai".
    - Refer to people by name when clear, otherwise by role (the moderator, the
      participant). NEVER write raw transcript labels like "them_1" or "self".
    - Skip greetings and filler; capture every substantive point that was made.

    Transcript slice:
    """

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
        RTILog.log("notes: generating from \(window.count) chars (since \(windowStartMs)ms)", category: "notes")

        guard let result = await TranscriptAnalysis.runText(
            sessionId: sessionId,
            sinceMs: sinceMs,
            smart: false,
            request: request,
            buildPrompt: { Self.notesPrompt + "\n" + $0 }
        ) else {
            // There WAS transcript to summarize but the model returned nothing —
            // a real failure worth surfacing (don't leave the user guessing).
            lastError = "Couldn't generate notes just now — will retry."
            RTILog.log("notes: model returned nothing for \(window.count)-char window", category: "notes")
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
