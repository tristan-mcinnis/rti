import Foundation

/// Renders a Session's transcript into the plain-text form the LLM reads
/// as part of a prompt. Sources from the live JSONL stream while a
/// session is in flight, and from the markdown body once the session has
/// been rendered to disk. Distinct from the UI transcript: uses raw
/// speaker IDs (`self`, `them_1`, `note`) and tags user-typed notes with
/// `[user note]:` so the model can distinguish them from spoken turns.
///
/// See `CONTEXT.md` for the **Transcript Context** domain definition.
@MainActor
enum TranscriptContext {

    /// Build the transcript context for a session.
    /// - Parameters:
    ///   - sessionId: which session to render.
    ///   - sinceMs: optional window cutoff. Only entries with `start_ms`
    ///     ≥ this value are included. Computed by callers from
    ///     `Date().timeIntervalSince(session.startedAt)`.
    /// - Returns: lines joined by `\n`. `[user note]: text` for note
    ///   rows, `<speaker>: text` otherwise.
    static func text(forSessionId sessionId: String, sinceMs: Int? = nil) -> String {
        let entries = CorpusBackedStore.transcripts(forSessionId: sessionId)
        let filtered: [TranscriptEntry]
        if let sinceMs {
            filtered = entries.filter { $0.startMs >= sinceMs }
        } else {
            filtered = entries
        }
        return format(filtered)
    }

    /// The end-ms of the transcript window for the given session. Used
    /// by periodic analysis controllers to advance their watermarks after
    /// processing a window, so the next cycle picks up only fresh entries.
    /// Returns nil when there are no entries.
    static func watermarkEndMs(forSessionId sessionId: String, sinceMs: Int? = nil) -> Int? {
        let entries = CorpusBackedStore.transcripts(forSessionId: sessionId)
        let filtered = sinceMs.map { s in entries.filter { $0.startMs >= s } } ?? entries
        return filtered.last?.startMs
    }

    /// Pure formatter — exposed for tests and for callers that already
    /// have entries in hand.
    ///
    /// Notes the user typed during a session are hoisted into a dedicated
    /// "User notes" preamble at the top so the LLM treats them as
    /// authoritative corrections (e.g. "Kline is actually Client") rather
    /// than as low-priority lines buried in chronological order. They are
    /// also left inline at their original timestamp so context isn't lost.
    static func format(_ entries: [TranscriptEntry]) -> String {
        let notes = entries.filter { $0.speakerId == "note" }
        let inline = entries
            .map { e in
                e.speakerId == "note"
                    ? "[user note]: \(e.text)"
                    : "\(e.speakerId): \(e.text)"
            }
            .joined(separator: "\n")
        guard !notes.isEmpty else { return inline }
        let header = "## User notes (authoritative — trust these over any transcript ambiguity)"
        let bullets = notes.map { "- \($0.text)" }.joined(separator: "\n")
        return "\(header)\n\(bullets)\n\n\(inline)"
    }
}
