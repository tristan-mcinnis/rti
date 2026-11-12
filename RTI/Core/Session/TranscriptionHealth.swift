import Foundation

/// Whether live transcription is actually flowing. Driven by the Soniox
/// connection lifecycle and surfaced in the UI so the user always knows if
/// their words are being captured — not just whether a session is "running".
public enum TranscriptionHealth: Equatable, Sendable {
    /// No session, or the connection is fully torn down.
    case idle
    /// Opening the first connection for this session.
    case connecting
    /// Connected and streaming audio.
    case live
    /// Dropped mid-session; retrying with backoff.
    case reconnecting
    /// Gave up after retries, or hit a non-retryable failure.
    case failed
}

/// Original provider speech and operator notes have separate clocks. Interim and
/// translated words can change the screen without advancing either final-speech clock.
public struct TranscriptReaderActivity: Equatable, Sendable {
    public private(set) var lastSpokenMs: Int?
    public private(set) var lastNoteMs: Int?

    public init() {}

    public mutating func record(_ entry: LiveEntry) {
        if entry.speakerId == "note" {
            lastNoteMs = max(lastNoteMs ?? 0, entry.startMs)
        } else if entry.translationStatus != "translation", !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let offset = entry.tokens.lazy.map(\.endMs).max() ?? entry.startMs
            lastSpokenMs = max(lastSpokenMs ?? 0, offset)
        }
    }

    public mutating func replaceNotes(at latest: Int?) { lastNoteMs = latest }

    public func caption(elapsedMs: Int) -> String {
        func age(_ offset: Int) -> String {
            let seconds = max(0, elapsedMs - offset) / 1000
            if seconds < 5 { return "just now" }
            return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
        }
        let speech = lastSpokenMs.map { "Speech " + age($0) } ?? "Awaiting first spoken words"
        return lastNoteMs.map { speech + " · Note " + age($0) } ?? speech
    }
}
