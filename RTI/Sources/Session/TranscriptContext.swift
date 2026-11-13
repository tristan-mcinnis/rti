import Foundation
import RTICore

/// Renders the live session transcript into the plain-text form the LLM reads
/// as part of an Auto-mode prompt. Ephemeral build: the only source is
/// `SessionCoordinator.shared.liveEntries` (in memory). Raw speaker IDs
/// (`remote_1`, `self`) are relabeled to human ones (`Speaker 1`, `Me`) BEFORE
/// the model sees them — prompt rules alone proved insufficient (the model
/// echoed `them_2` into generated notes). User-typed notes are tagged
/// `[user note]:` so the model can distinguish them from spoken turns.
///
/// The `sessionId` parameter is vestigial — there is only ever one live
/// session — but kept on the signatures so call sites read clearly.
@MainActor
enum TranscriptContext {
    /// Live entries, optionally windowed to those after `sinceMs`.
    /// Translation tokens are excluded — Auto mode reads the
    /// original spoken transcript, not the live-translated duplicate, which
    /// would otherwise double the prompt and confuse the model.
    /// The live entries are sorted by `startMs`, so a window is found by
    /// binary search and only the entries after the watermark are read
    /// (2026-11-13 M1 audit: every pass filtered two hours of entries).
    private static func entries(sinceMs: Int?, untilMs: Int? = nil) -> [LiveEntry] {
        let session = SessionCoordinator.shared
        let all = session.liveEntries
        // A seeded render proof may hand over entries in any order.
        guard !session.usesSeededTranscript else {
            return all.filter { entry in
                entry.translationStatus != "translation" && (sinceMs.map { entry.startMs > $0 } ?? true)
                    && (untilMs.map { entry.startMs <= $0 } ?? true)
            }
        }
        let lower = sinceMs.map { firstIndex(in: all) { $0.startMs > $1 } ($0) } ?? all.startIndex
        let upper = untilMs.map { firstIndex(in: all) { $0.startMs > $1 } ($0) } ?? all.endIndex
        guard lower < upper else { return [] }
        return all[lower..<upper].filter { $0.translationStatus != "translation" }
    }

    /// The first index whose entry is past `bound`, by binary search.
    private static func firstIndex(in entries: [LiveEntry], where isPast: @escaping (LiveEntry, Int) -> Bool) -> (Int) -> Int {
        { bound in
            var low = entries.startIndex
            var high = entries.endIndex
            while low < high {
                let middle = low + (high - low) / 2
                if isPast(entries[middle], bound) { high = middle } else { low = middle + 1 }
            }
            return low
        }
    }

    /// Build the transcript context for the live session. Lines joined by
    /// `\n`: `[user note]: text` for note rows, `[mm:ss, label] text`
    /// otherwise. Labels come from `speakerLabel(for:names:)`: the audio leg
    /// (`Me`, `Them`), plus a name only when the user typed one. With live
    /// diarization off (the default) every system-leg row is `Them`, so a
    /// label never tells one person on the other side from another.
    /// `untilMs` (inclusive) bounds the window's end, so Auto can re-read the
    /// minutes before its watermark as context only. `hoistNotes` and
    /// `evidenceRule` let a caller that renders two windows into one prompt
    /// keep the notes header and the evidence rule out of one of them.
    static func text(
        forSessionId _: String,
        sinceMs: Int? = nil,
        untilMs: Int? = nil,
        hoistNotes: Bool = true,
        evidenceRule: Bool = true,
        roles: TurnRoles.Context? = nil
    ) -> String {
        let window = entries(sinceMs: sinceMs, untilMs: untilMs)
        return format(window, label: speakerLabeler(for: window), includeTimestamps: true,
                      hoistNotes: hoistNotes, evidenceRule: evidenceRule, roles: roles)
    }

    /// The words said after `sinceMs`, with no labels, times or rules: the
    /// text Auto builds its vault query from (`AutoVaultQuery`). Typed notes
    /// count as said.
    static func spokenText(sinceMs: Int?) -> String {
        LiveTranscriptPresentation.utterances(from: entries(sinceMs: sinceMs))
            .map(\.text)
            .joined(separator: "\n")
    }

    /// New respondent characters after `sinceMs`, split at question marks
    /// and read by the shared role rule (`AutoResearchSignals`). A research
    /// Auto pass skips a window with too few.
    static func respondentCharacters(sinceMs: Int?, roles: TurnRoles.Context) -> Int {
        let sessionHasThem = SessionCoordinator.shared.liveEntries.contains {
            $0.translationStatus != "translation" && $0.speakerId != "note" && SpeakerEvidence.leg(for: $0.speakerId) == "Them"
        }
        let turns = rolePieces(LiveTranscriptPresentation.utterances(from: entries(sinceMs: sinceMs)))
            .filter { $0.speakerId != "note" }
            .map { (isThem: SpeakerEvidence.leg(for: $0.speakerId) == "Them", text: $0.text) }
        return AutoResearchSignals.respondentCharacters(turns, sessionHasThem: sessionHasThem, context: roles)
    }

    /// The start of the last system-leg line and of the last spoken line,
    /// for the silent-leg signal.
    static func lastSpeech() -> (them: Int?, any: Int?) {
        let spoken = SessionCoordinator.shared.liveEntries.lazy.reversed()
            .filter { $0.translationStatus != "translation" && $0.speakerId != "note" }
        return (spoken.first { SpeakerEvidence.leg(for: $0.speakerId) == "Them" }?.startMs, spoken.first?.startMs)
    }

    /// Every note the user typed in this session, oldest first. A note is
    /// always its own utterance, so the notes are filtered first and only
    /// they are grouped.
    static func userNotes() -> [String] {
        let notes = SessionCoordinator.shared.liveEntries.filter {
            $0.speakerId == "note" && $0.translationStatus != "translation"
        }
        return LiveTranscriptPresentation.utterances(from: notes).map(\.text)
    }

    /// Human labels for raw speaker IDs, the same ones the Transcript tab
    /// shows (`LiveTranscriptPresentation.label`, live names included), except
    /// that the unnamed mic wearer is `Me`. Derived from the id alone, so a
    /// label means the same person in every Auto-mode window and in the UI.
    /// (Numbering by first appearance made the model's "Speaker 2" a
    /// different person from the Transcript tab's, and ignored renames.)
    private static func speakerLabeler(for _: [LiveEntry]) -> (String) -> String {
        let names = SpeakerNameStore.shared.names
        return { speakerLabel(for: $0, names: names) }
    }

    /// One speaker id as the assistant reads it; shared with Assist's recent
    /// transcript so every prompt names speakers the same way.
    static func speakerLabel(for id: String, names: [String: String]) -> String {
        let named = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let leg = SpeakerEvidence.leg(for: id)
        let isNamed = named?.isEmpty == false
        // A name the user typed is evidence; a live cluster number is not.
        if !isNamed, !SessionCoordinator.shared.speakerPolicy.liveLabelsEnabled { return leg }
        switch SpeakerEvidence.resolve(speakerID: id, named: isNamed) {
        case .legOnly: return leg
        case .confirmed: return "\(leg) / \(named ?? leg) (confirmed)"
        case .unverified: return "\(leg) (unverified speaker)"
        }

    }

    /// The shared role rule's split: a question and the answer merged into
    /// one utterance become two lines, the later one at an interpolated time.
    private static func rolePieces(_ utterances: [LiveTranscriptPresentation.Utterance]) -> [LiveTranscriptPresentation.Utterance] {
        utterances.flatMap { utterance -> [LiveTranscriptPresentation.Utterance] in
            guard utterance.speakerId != "note" else { return [utterance] }
            let pieces = TurnRoles.splitAtQuestions(utterance.text)
            guard pieces.count > 1 else { return [utterance] }
            let length = max(1, utterance.text.count)
            let span = max(0, utterance.endMs - utterance.startMs)
            let starts = pieces.map { utterance.startMs + span * $0.offset / length }
            return pieces.enumerated().map { index, piece in
                utterance.piece(piece.text, startMs: starts[index],
                                endMs: index + 1 < starts.count ? max(starts[index], starts[index + 1]) : utterance.endMs)
            }
        }
    }

    /// A lower bound after `sinceMs` that keeps only the newest
    /// `keepCharacters` of spoken text, or nil when the window already fits.
    /// The bound is exclusive, like every `sinceMs`: the entry it names is
    /// the newest one left out.
    static func newestWindowStart(sinceMs: Int?, keepCharacters: Int) -> Int? {
        var kept = 0
        for entry in entries(sinceMs: sinceMs).reversed() {
            kept += entry.text.count
            if kept > keepCharacters { return entry.startMs }
        }
        return nil
    }

    /// The end-ms of the transcript window. Used by the periodic Auto-mode
    /// controller to advance its watermark. Returns nil when empty.
    static func watermarkEndMs(forSessionId _: String, sinceMs: Int? = nil) -> Int? {
        guard !SessionCoordinator.shared.usesSeededTranscript else { return entries(sinceMs: sinceMs).last?.startMs }
        let last = SessionCoordinator.shared.liveEntries.last { $0.translationStatus != "translation" }?.startMs
        guard let last else { return nil }
        return sinceMs.map { last > $0 ? last : nil } ?? last
    }

    /// Pure formatter — exposed for tests and for callers that already
    /// have entries in hand.
    ///
    /// Notes the user typed during a session are hoisted into a dedicated
    /// "User notes" preamble at the top so the LLM treats them as
    /// authoritative corrections rather than low-priority chronological
    /// lines. They are also left inline so context isn't lost.
    static func format(
        _ entries: [LiveEntry],
        label: ((String) -> String)? = nil,
        noteLabel: String = "[user note]",
        includeTimestamps: Bool = false,
        hoistNotes: Bool = true,
        evidenceRule includeEvidenceRule: Bool = true,
        roles: TurnRoles.Context? = nil
    ) -> String {
        let label = label ?? speakerLabeler(for: entries)
        // Provider messages can end halfway through a word. Group complete
        // spoken phrases before adding labels, using the reader's same rule.
        var utterances = LiveTranscriptPresentation.utterances(from: entries)
        var roleOf: [Int: SpeechRole] = [:]
        if let roles {
            utterances = rolePieces(utterances)
            let spoken = utterances.enumerated().map { index, e in
                TurnRoles.Spoken(id: String(index), speaker: e.speakerId, startMs: e.startMs, endMs: e.endMs, text: e.text)
            }
            let sampleFrom = (spoken.map(\.endMs).max() ?? 0) - GuideTranscript.roomSampleMs
            let echoes = TurnRoles.micEchoIDs(spoken, against: spoken, roomSample: spoken.filter { $0.endMs >= sampleFrom })
            var kept: [LiveTranscriptPresentation.Utterance] = []
            for (index, e) in utterances.enumerated() where !echoes.contains(String(index)) {
                if e.speakerId != "note", SpeakerEvidence.leg(for: e.speakerId) == "Them" {
                    roleOf[kept.count] = TurnRoles.role(speaker: e.speakerId, text: e.text, context: roles)
                }
                kept.append(e)
            }
            utterances = kept
        }
        let notes = utterances.filter { $0.speakerId == "note" }
        let inline = utterances.enumerated()
            .map { index, e in
                var speaker = e.speakerId == "note" ? noteLabel : label(e.speakerId)
                if let role = roleOf[index], role != .unknown {
                    speaker += ", \(role.rawValue)"
                }
                if includeTimestamps {
                    return "[\(TimeFormat.elapsedMs(e.startMs)), \(speaker)] \(e.text)"
                }
                return "\(speaker): \(e.text)"
            }
            .joined(separator: "\n")
        let evidenceRule = includeEvidenceRule && includeTimestamps && !inline.isEmpty
            ? "Me and Them identify audio inputs. Only a confirmed mapping supports a name. An unverified voice cannot establish who said a line or how many people agreed.\n"
            + (roles == nil ? "" : "A role after Them (moderator or respondent) is a guess from the words, never a speaker identity. Never cite a moderator line as evidence.\n")
            : ""
        guard hoistNotes, !notes.isEmpty else { return evidenceRule + inline }
        let header = "## User notes (authoritative — trust these over any transcript ambiguity)"
        let bullets = notes.map { "- \($0.text)" }.joined(separator: "\n")
        return "\(header)\n\(bullets)\n\n\(evidenceRule)\(inline)"
    }
}
