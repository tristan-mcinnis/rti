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

    ⚠️ CRITICAL FORMAT RULE — applies to EVERY Chinese term, everywhere in your
    output: write it as 中文 (pīnyīn, English meaning). The pinyin is MANDATORY,
    with tone marks. A bare Chinese term WITHOUT pinyin is a format error.
    Examples: 没得选 (méi dé xuǎn, no other choice); 撞衫 (zhuàngshān, wearing the
    same outfit as someone); 胸垫 (xiōngdiàn, chest pads). Never write 没得选 alone.

    LANGUAGE: Write the notes in ENGLISH. The conversation may be in Chinese or
    another language; translate as you go. You MAY keep a short essential term in
    its original language when the English alone loses meaning, ALWAYS in the
    中文 (pīnyīn, English) format above. Do NOT write whole bullets in Chinese.
    Keep people's names and brand names as spoken.

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
    - MODERATOR: the person asking the questions and steering topics is "the
      moderator" — call them that, never "Speaker N". Log their questions only
      when needed to make an answer intelligible; participants' content is what
      matters.
    - NAMES: refer to participants by name when clear, otherwise keep the
      transcript's "Speaker N" label. Render Chinese forms of address properly:
      王女士 → "Ms. Wang (王女士)", 李先生 → "Mr. Li (李先生)" — NEVER ad-hoc
      romanizations like "Wang nvshi". Once a name is known, use it in every
      later bullet. NEVER invent labels like "them_1", "Participant 1", or "self".
    - GARBLED TERMS: if a Chinese term looks mis-transcribed or you are not
      confident what it means, do NOT invent a confident gloss — write it as
      term (unclear) or use the likely intended term with a ? — e.g. "工字背心?
      (racerback tank)".
    - Skip greetings and filler; capture every substantive point that was made.
    - VERBATIM QUOTES: when a participant says something vivid, surprising, or
      quotable, include the short verbatim phrase inline in its bullet —
      formatted "原话 (pinyin, English)" — these verbatims are gold for the
      debrief. At most 2–3 per block; only genuinely striking lines.
    - SIDE CONVERSATIONS: if a stretch is clearly off-topic chatter between
      observers — talk about software/tools, note-taking apps, screens, file
      syncing, scheduling other projects, or anything unrelated to the main
      discussion topic — OMIT it entirely. Do not summarize it, do not write
      "a side conversation occurred". If you cannot tell what an utterance
      means, drop it rather than guessing a garbled bullet.

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

        // Continuity: each tick only sees its 2-minute slice, so feed the
        // previous block back in — the model stops re-introducing people and
        // topics it already noted.
        let priorBlock = notes.last.map { prior in
            "PREVIOUS NOTES BLOCK (already written — context only; do NOT repeat "
            + "or re-introduce these people/points):\n\(prior.content)\n\n"
        } ?? ""
        guard let result = await TranscriptAnalysis.runText(
            sessionId: sessionId,
            sinceMs: sinceMs,
            smart: false,
            request: request,
            buildPrompt: { Self.notesPrompt + "\n" + priorBlock + $0 }
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
