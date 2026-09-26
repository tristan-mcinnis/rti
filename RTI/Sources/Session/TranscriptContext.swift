import Foundation
import RTICore

/// Renders the live session transcript into the plain-text form the LLM reads
/// as part of an analysis prompt. Ephemeral build: the only source is
/// `SessionCoordinator.shared.liveEntries` (in memory). Raw speaker IDs
/// (`remote_1`, `self`) are relabeled to human ones (`Speaker 1`, `Me`) BEFORE
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
    /// Labels come from the speaker id, so "Speaker 2" means the same person
    /// in every periodic notes block and in the Transcript tab.
    static func text(forSessionId _: String, sinceMs: Int? = nil) -> String {
        let all = entries(sinceMs: nil)
        let window: [LiveEntry] = if let sinceMs {
            all.filter { $0.startMs >= sinceMs }
        } else {
            all
        }
        return format(window, label: speakerLabeler(for: all))
    }

    /// Like `text(forSessionId:)` but prefixes each spoken line with a
    /// `[mm:ss]` timestamp derived from `startMs`. Used by the discussion-
    /// guide matcher so the LLM can echo timestamps into its quote payloads.
    /// User notes are left without timestamps (they were typed, not spoken).
    ///
    /// Only entries at or after `sinceMs` are emitted.
    static func textWithTimestamps(forSessionId _: String, sinceMs: Int? = nil) -> String {
        let all = entries(sinceMs: nil)
        let window = entries(sinceMs: sinceMs)
        let label = speakerLabeler(for: all)
        return window.map { e in
            if e.speakerId == "note" {
                return "[user note]: \(e.text)"
            }
            let total = e.startMs / 1000
            let stamp = String(format: "[%d:%02d]", total / 60, total % 60)
            return "\(stamp) \(label(e.speakerId)): \(e.text)"
        }.joined(separator: "\n")
    }

    /// Human labels for raw speaker IDs, the same ones the Transcript tab
    /// shows (`LiveTranscriptPresentation.label`, live names included), except
    /// that the unnamed mic wearer is `Me`. Derived from the id alone, so a
    /// label means the same person in every analysis window and in the UI.
    /// (Numbering by first appearance made the model's "Speaker 2" a
    /// different person from the Transcript tab's, and ignored renames.)
    private static func speakerLabeler(for _: [LiveEntry]) -> (String) -> String {
        let names = SpeakerNameStore.shared.names
        return { speakerLabel(for: $0, names: names) }
    }

    /// One speaker id as the assistant reads it; shared with Assist's recent
    /// transcript so every prompt names speakers the same way.
    static func speakerLabel(for id: String, names: [String: String]) -> String {
        if id == "self", names["self"] == nil { return "Me" }
        return LiveTranscriptPresentation.label(for: id, names: names)
    }

    /// The end-ms of the transcript window. Used by periodic analysis
    /// controllers to advance their watermarks. Returns nil when empty.
    static func watermarkEndMs(forSessionId _: String, sinceMs: Int? = nil) -> Int? {
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
