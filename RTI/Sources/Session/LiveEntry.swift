import Foundation

/// A single committed row of the live in-memory transcript. Speaker rows use
/// the labels from `SpeakerLabelMapping` (`"self"`, `"them"`, `"them_1"`, …);
/// user notes use `speakerId == "note"`. `startMs` is an offset on the
/// session timeline. Ephemeral build: these live in memory for the duration
/// of a session only.
struct LiveEntry: Identifiable {
    let id = UUID()
    let speakerId: String
    let text: String
    let startMs: Int
    let confidence: Double
    /// "none" | "original" | "translation"
    let translationStatus: String
    /// Language code (e.g. "en", "fr") — nil for pre-translation tokens
    let language: String?
    /// Original language for translation tokens
    let sourceLanguage: String?
}
