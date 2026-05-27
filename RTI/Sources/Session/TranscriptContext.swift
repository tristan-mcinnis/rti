import Foundation

/// Renders the live session transcript into the plain-text form the LLM reads
/// as part of an analysis prompt. Ephemeral build: the only source is
/// `SessionCoordinator.shared.liveEntries` (in memory). Uses raw speaker IDs
/// (`self`, `them_1`, `note`) and tags user-typed notes with `[user note]:`
/// so the model can distinguish them from spoken turns.
///
/// The `sessionId` parameter is vestigial — there is only ever one live
/// session — but kept on the signatures so analysis call sites read clearly.
@MainActor
enum TranscriptContext {

    /// Live entries, optionally windowed to those at or after `sinceMs`.
    private static func entries(sinceMs: Int?) -> [LiveEntry] {
        let all = SessionCoordinator.shared.liveEntries
        guard let sinceMs else { return all }
        return all.filter { $0.startMs >= sinceMs }
    }

    /// Build the transcript context for the live session. Lines joined by
    /// `\n`: `[user note]: text` for note rows, `<speaker>: text` otherwise.
    static func text(forSessionId sessionId: String, sinceMs: Int? = nil) -> String {
        format(entries(sinceMs: sinceMs))
    }

    /// Like `text(forSessionId:)` but prefixes each spoken line with a
    /// `[mm:ss]` timestamp derived from `startMs`. Used by the discussion-
    /// guide matcher so the LLM can echo timestamps into its quote payloads.
    /// User notes are left without timestamps (they were typed, not spoken).
    static func textWithTimestamps(forSessionId sessionId: String) -> String {
        entries(sinceMs: nil).map { e in
            if e.speakerId == "note" {
                return "[user note]: \(e.text)"
            }
            let total = e.startMs / 1000
            let stamp = String(format: "[%d:%02d]", total / 60, total % 60)
            return "\(stamp) \(e.speakerId): \(e.text)"
        }.joined(separator: "\n")
    }

    /// The end-ms of the transcript window. Used by periodic analysis
    /// controllers to advance their watermarks. Returns nil when empty.
    static func watermarkEndMs(forSessionId sessionId: String, sinceMs: Int? = nil) -> Int? {
        entries(sinceMs: sinceMs).last?.startMs
    }

    /// Pure formatter — exposed for tests and for callers that already
    /// have entries in hand.
    ///
    /// Notes the user typed during a session are hoisted into a dedicated
    /// "User notes" preamble at the top so the LLM treats them as
    /// authoritative corrections rather than low-priority chronological
    /// lines. They are also left inline so context isn't lost.
    static func format(_ entries: [LiveEntry]) -> String {
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
