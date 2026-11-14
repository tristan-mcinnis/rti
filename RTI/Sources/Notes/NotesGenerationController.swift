import Foundation
import Observation
import RTICore

extension Notification.Name {
    /// A notes pass appended at least one block.
    /// `userInfo["sessionID"]` is the session, `userInfo["notes"]` every block.
    static let rtiNotesBlockAdded = Notification.Name("rtiNotesBlockAdded")
}

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

    private let request: LLMRequest
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
    #if DEBUG
        /// Test seam: invented note blocks for render and latency proofs.
        func seedForRenderProof(_ notes: [GeneratedNote]) {
            self.notes = notes
        }
    #endif

    init(request: LLMRequest = LLMRequest(priority: .background)) {
        self.request = request
    }

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
    func generate(sessionId: String, timeout: Double? = nil) async -> Int? {
        guard !isGenerating else { return nil }
        let passGeneration = generation
        isGenerating = true
        // A reset may admit a new pass while this one is suspended. Only
        // the owning generation can release its busy state.
        defer {
            if passGeneration == generation { isGenerating = false }
        }
        lastError = nil

        var windowStartMs = lastNotedMs
        var sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs
        // Set when the backlog cap dropped the older part of the window.
        var skipped: (startMs: Int, endMs: Int)?

        // Nothing new spoken since the last note → skip quietly (no error).
        var window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }
        // A backlog (a failed pass, or Notes turned on mid-call) keeps only
        // its newest part, so one prompt never carries an hour of talk.
        if let capped = Self.backlogStart(window: window, sinceMs: sinceMs,
                                          sessionElapsedMs: SessionCoordinator.shared.startedAt.map { Int(Date().timeIntervalSince($0) * 1000) }) {
            skipped = (windowStartMs, capped)
            windowStartMs = capped
            sinceMs = capped
            window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            RTILog.log("notes: backlog capped to the newest \(Self.backlogCharacters) characters", category: .notes)
        }
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
        let response = await request.collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)], smart: false, timeoutOverride: timeout
        )
        guard passGeneration == generation else { return nil }
        guard let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // There WAS transcript to summarize but the model returned nothing.
            // A real failure worth surfacing (don't leave the user guessing).
            lastError = "Couldn't generate notes just now. RTI tries again on the next pass."
            RTILog.log("notes: model returned nothing for \(window.count)-char window", category: .notes)
            return nil
        }

        // Advance the watermark even if this block was empty, so we never
        // re-cover the same stretch.
        lastNotedMs = endMs
        let blocksBefore = notes.count
        // The cap is a silent hole otherwise: notes.md and the /meeting
        // sidecar would read as if nothing was said in it.
        if let skipped, skipped.endMs > skipped.startMs {
            notes.append(Self.skippedNote(startMs: skipped.startMs, endMs: skipped.endMs))
        }

        let parsed = Self.parse(response)
        if !parsed.bullets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append(GeneratedNote(
                timestamp: Date(),
                rangeStartMs: windowStartMs,
                rangeEndMs: endMs,
                title: parsed.title,
                content: parsed.bullets
            ))
        }
        // A block that lands after Stop archived the session (a manual
        // "Write notes now", or a pass Stop did not wait for) is saved to
        // notes.md and the sidecar by the late-archive refresher.
        if notes.count > blocksBefore {
            NotificationCenter.default.post(name: .rtiNotesBlockAdded, object: nil,
                                            userInfo: ["sessionID": sessionId, "notes": notes])
        }
        return endMs
    }

    /// One bounded pass at Stop over the talk since the last tick, which no
    /// tick would ever cover: the scheduler stops with the call. Runs beside
    /// the Guide and Codebook finish, under the same 8 s limit, so a slow
    /// provider cannot hold the archive back.
    func finish(sessionId: String, timeout: Double = 8) async {
        // Lite writes no live notes, so Stop runs no final notes pass.
        guard RTILiteSettings.runs(task: "notes") else { return }
        guard self.sessionId == sessionId, UserDefaults.standard.bool(forKey: NotesSettings.enabledKey) else { return }
        // The request timeout bounds a silent provider; the race bounds a slow
        // stream. Stop goes on at the earlier end, and a pass still running
        // is cancelled (its late result cannot reach the next session).
        let (ended, end) = AsyncStream<Void>.makeStream()
        let pass = Task {
            _ = await generate(sessionId: sessionId, timeout: timeout)
            end.finish()
        }
        let limit = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            end.finish()
        }
        for await _ in ended {}
        limit.cancel()
        pass.cancel()
    }

    static let skippedTitle = "Notes skipped"

    /// The marker for a stretch the backlog cap left without notes.
    static func skippedNote(startMs: Int, endMs: Int) -> GeneratedNote {
        GeneratedNote(timestamp: Date(), rangeStartMs: startMs, rangeEndMs: endMs, title: skippedTitle,
                      content: "- RTI wrote no notes for this stretch: the notes service did not answer in time, "
                          + "or Notes was turned on late. The transcript and the audio keep every word of it.")
    }

    /// The most transcript text one backlog pass sends (2026-11-13 M1 audit).
    static let backlogCharacters = 6_000

    /// Where a backlog window starts, or nil when the window is not a
    /// backlog. A backlog is longer than `backlogCharacters` and covers more
    /// than two scheduler intervals: a failed pass kept its watermark, or
    /// Notes was turned on late. Normal windows are never cut.
    static func backlogStart(window: String, sinceMs: Int?, sessionElapsedMs: Int?,
                             interval: TimeInterval = NotesSettings.tickInterval) -> Int? {
        guard window.count > backlogCharacters else { return nil }
        let coveredMs = (sessionElapsedMs ?? Int.max) - (sinceMs ?? 0)
        guard coveredMs > Int(interval * 2000) else { return nil }
        return TranscriptContext.newestWindowStart(sinceMs: sinceMs, keepCharacters: backlogCharacters)
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
