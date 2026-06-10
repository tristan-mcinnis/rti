import Foundation
import RTICore

/// Renders the live session transcript into the plain-text form the LLM reads
/// as part of an analysis prompt. Ephemeral build: the only source is
/// `SessionCoordinator.shared.liveEntries` (in memory). Raw speaker IDs
/// (`them_1`, `self`) are relabeled to human ones (`Speaker 1`, `Me`) BEFORE
/// the model sees them — prompt rules alone proved insufficient (the model
/// echoed `them_2` into generated notes). User-typed notes are tagged
/// `[user note]:` so the model can distinguish them from spoken turns.
///
/// The `sessionId` parameter is vestigial — there is only ever one live
/// session — but kept on the signatures so analysis call sites read clearly.
@MainActor
enum TranscriptContext {

    /// Live entries, optionally windowed to those at or after `sinceMs`.
    /// Translation tokens are excluded — analysis (notes, guide) reads the
    /// original spoken transcript, not the live-translated duplicate, which
    /// would otherwise double the prompt and confuse the model.
    private static func entries(sinceMs: Int?) -> [LiveEntry] {
        let all = SessionCoordinator.shared.liveEntries.filter { $0.translationStatus != "translation" }
        guard let sinceMs else { return all }
        return all.filter { $0.startMs >= sinceMs }
    }

    /// Build the transcript context for the live session. Lines joined by
    /// `\n`: `[user note]: text` for note rows, `Speaker N: text` otherwise.
    /// Speaker numbering is derived from the FULL session (not the window) so
    /// "Speaker 2" means the same person in every periodic notes block.
    static func text(forSessionId sessionId: String, sinceMs: Int? = nil) -> String {
        format(entries(sinceMs: sinceMs), label: speakerLabeler(for: entries(sinceMs: nil)))
    }

    /// Like `text(forSessionId:)` but prefixes each spoken line with a
    /// `[mm:ss]` timestamp derived from `startMs`. Used by the discussion-
    /// guide matcher so the LLM can echo timestamps into its quote payloads.
    /// User notes are left without timestamps (they were typed, not spoken).
    static func textWithTimestamps(forSessionId sessionId: String) -> String {
        let all = entries(sinceMs: nil)
        let label = speakerLabeler(for: all)
        return all.map { e in
            if e.speakerId == "note" {
                return "[user note]: \(e.text)"
            }
            let total = e.startMs / 1000
            let stamp = String(format: "[%d:%02d]", total / 60, total % 60)
            return "\(stamp) \(label(e.speakerId)): \(e.text)"
        }.joined(separator: "\n")
    }

    /// Appearance-ordered human labels for raw speaker IDs — `Me` for the
    /// mic channel, `Speaker N` for everyone else (matching SessionArchive's
    /// rendering). IMPORTANT: numbering must be stable across analysis
    /// windows, so it is derived from the FULL entry list passed in, in
    /// first-appearance order.
    private static func speakerLabeler(for entries: [LiveEntry]) -> (String) -> String {
        var numbers: [String: Int] = [:]
        var next = 1
        for e in entries where e.speakerId != "note" && e.speakerId != "self" {
            if numbers[e.speakerId] == nil {
                numbers[e.speakerId] = next
                next += 1
            }
        }
        return { id in
            if id == "self" { return "Me" }
            if let n = numbers[id] { return "Speaker \(n)" }
            return "Speaker ?"
        }
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
    static func format(_ entries: [LiveEntry], label: ((String) -> String)? = nil) -> String {
        let label = label ?? speakerLabeler(for: entries)
        let notes = entries.filter { $0.speakerId == "note" }
        let inline = entries
            .map { e in
                e.speakerId == "note"
                    ? "[user note]: \(e.text)"
                    : "\(label(e.speakerId)): \(e.text)"
            }
            .joined(separator: "\n")
        guard !notes.isEmpty else { return inline }
        let header = "## User notes (authoritative — trust these over any transcript ambiguity)"
        let bullets = notes.map { "- \($0.text)" }.joined(separator: "\n")
        return "\(header)\n\(bullets)\n\n\(inline)"
    }
}
