import Foundation

/// A single committed row of the live in-memory transcript. Speaker rows use
/// the labels from `SpeakerLabelMapping` (`"self"`, `"them"`, `"them_1"`, …);
/// user notes use `speakerId == "note"`. `startMs` is an offset on the
/// session timeline. Ephemeral build: these live in memory for the duration
/// of a session only.
public struct LiveEntry: Identifiable {
    public let id = UUID()
    public let speakerId: String
    public let text: String
    public let startMs: Int
    public let confidence: Double
    /// "none" | "original" | "translation"
    public let translationStatus: String
    /// Language code (e.g. "en", "fr") — nil for pre-translation tokens
    public let language: String?
    /// Original language for translation tokens
    public let sourceLanguage: String?

    public init(
        speakerId: String,
        text: String,
        startMs: Int,
        confidence: Double,
        translationStatus: String,
        language: String?,
        sourceLanguage: String?
    ) {
        self.speakerId = speakerId
        self.text = text
        self.startMs = startMs
        self.confidence = confidence
        self.translationStatus = translationStatus
        self.language = language
        self.sourceLanguage = sourceLanguage
    }
}
