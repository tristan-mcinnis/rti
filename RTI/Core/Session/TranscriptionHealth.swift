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
