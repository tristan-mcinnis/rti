import Foundation

/// A single committed row of the live in-memory transcript. Speaker rows use
/// the labels from `SpeakerLabelMapping` (`"self"`, `"room_1"`, `"remote_1"`, …);
/// user notes use `speakerId == "note"`. `startMs` is an offset on the
/// session timeline. Ephemeral build: these live in memory for the duration
/// of a session only.
public struct LiveEntry: Identifiable {
    /// Exact provider timing, retained separately from the archive/notes batch
    /// text so another audio leg can appear between words of the same batch.
    public struct TimedToken: Equatable, Sendable {
        public let text: String
        public let startMs: Int
        public let endMs: Int

        public init(text: String, startMs: Int, endMs: Int) {
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    /// Provider tokens already carry their word boundaries. A standalone
    /// entry (for example a typed note or fixture) is a separate text block.
    public enum TextOrigin: Equatable, Sendable {
        case standalone
        case providerTokens
        /// Peer audio corrected this fragment's interior. Its explicit edge
        /// whitespace and display lineage belong to the canonical fragment.
        case providerCorrection(continuingStreamID: UUID?)
    }

    public let id: UUID
    public let speakerId: String
    public let text: String
    /// Empty for authored/legacy entries and peer corrections without a known
    /// word alignment. Those remain one explicit presentation fragment.
    public let tokens: [TimedToken]
    public let textOrigin: TextOrigin
    /// One provider socket's token sequence. A reconnect starts a new sequence
    /// whose first token must not be glued to the previous stream's last one.
    public let streamID: UUID?
    /// A correction keeps its canonical display run while `streamID` records
    /// the stream that supplied the replacement text.
    public var displayStreamID: UUID? {
        if case let .providerCorrection(continuingStreamID) = textOrigin {
            return continuingStreamID
        }
        return streamID
    }
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
        sourceLanguage: String?,
        id: UUID = UUID(),
        textOrigin: TextOrigin = .standalone,
        streamID: UUID? = nil,
        tokens: [TimedToken] = []
    ) {
        self.id = id
        self.speakerId = speakerId
        self.text = text
        self.tokens = tokens
        self.textOrigin = textOrigin
        self.streamID = streamID
        self.startMs = startMs
        self.confidence = confidence
        self.translationStatus = translationStatus
        self.language = language
        self.sourceLanguage = sourceLanguage
    }
}
