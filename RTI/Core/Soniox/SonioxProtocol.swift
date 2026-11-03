import Foundation

public struct SonioxWord {
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let speaker: Int
    public let confidence: Double
    public let isFinal: Bool
    /// "none" | "original" | "translation"
    public let translationStatus: String
    /// Language code of the token (e.g. "en", "fr")
    public let language: String?
    /// Original language for translated tokens
    public let sourceLanguage: String?

    public init(
        text: String,
        startMs: Int,
        endMs: Int,
        speaker: Int,
        confidence: Double,
        isFinal: Bool,
        translationStatus: String,
        language: String?,
        sourceLanguage: String?
    ) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.confidence = confidence
        self.isFinal = isFinal
        self.translationStatus = translationStatus
        self.language = language
        self.sourceLanguage = sourceLanguage
    }
}

public struct TranslationConfig: Codable, Equatable {
    /// "one_way" or "two_way"
    let type: String
    /// Target language for one-way translation (e.g. "fr", "es")
    let target_language: String?
    /// Language A for two-way translation
    let language_a: String?
    /// Language B for two-way translation
    let language_b: String?

    enum CodingKeys: String, CodingKey {
        case type
        case target_language
        case language_a
        case language_b
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(target_language, forKey: .target_language)
        try c.encodeIfPresent(language_a, forKey: .language_a)
        try c.encodeIfPresent(language_b, forKey: .language_b)
    }

    public static func oneWay(targetLanguage: String) -> TranslationConfig {
        TranslationConfig(type: "one_way", target_language: targetLanguage, language_a: nil, language_b: nil)
    }

    public static func twoWay(languageA: String, languageB: String) -> TranslationConfig {
        TranslationConfig(type: "two_way", target_language: nil, language_a: languageA, language_b: languageB)
    }
}

/// Soniox `context` object: what the model should know about this audio. Holds
/// the meeting's setting and participants, and the project's unusual names.
/// See https://docs.soniox.com/stt/concepts/context
public struct SonioxContext: Codable, Equatable, Sendable {
    public struct GeneralEntry: Codable, Equatable, Sendable {
        public let key: String
        public let value: String
    }

    public let general: [GeneralEntry]
    public let terms: [String]?

    /// Soniox refuses more than 8,000 tokens, which stops the session. One
    /// Chinese character can be a token or more, so stay well under.
    static let maxEncodedCharacters = 4_000
    private static let maxParticipants = 30
    private static let maxValueCharacters = 400
    private static let maxNameCharacters = 80
    private static let maxTermCharacters = 60

    public static func forMeeting(
        callType: String,
        project: String?,
        meetingTitle: String?,
        participants: [String],
        terms: [String]
    ) -> SonioxContext {
        let names = unique(participants.filter { !$0.contains("@") }, maxCharacters: maxNameCharacters)
            .prefix(maxParticipants)
        let pairs: [(String, String?)] = [
            ("Setting", callType),
            ("Project", project),
            ("Meeting", meetingTitle),
            ("Participants", names.isEmpty ? nil : names.joined(separator: ", ")),
        ]
        let general = pairs.compactMap { key, value -> GeneralEntry? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return GeneralEntry(key: key, value: String(value.prefix(maxValueCharacters)))
        }
        var kept = unique(terms, maxCharacters: maxTermCharacters)
        var context = SonioxContext(general: general, terms: kept.isEmpty ? nil : kept)
        while !kept.isEmpty, context.encodedCharacterCount > maxEncodedCharacters {
            kept.removeLast()
            context = SonioxContext(general: general, terms: kept.isEmpty ? nil : kept)
        }
        return context
    }

    /// One term per line. Blank lines and `#` comments are skipped.
    public static func terms(inFile text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    var encodedCharacterCount: Int {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self).count } ?? 0
    }

    private static func unique(_ values: [String], maxCharacters: Int) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxCharacters && seen.insert($0.lowercased()).inserted }
    }
}

public struct SonioxConfigMessage: Codable {
    let model: String
    let audio_format: String
    let sample_rate: Int
    let num_channels: Int
    let language_hints: [String]
    let enable_speaker_diarization: Bool
    let enable_language_identification: Bool
    let translation: TranslationConfig?
    let context: SonioxContext?

    public static func `default`(translation: TranslationConfig? = nil, context: SonioxContext? = nil) -> SonioxConfigMessage {
        // en+zh always: meetings here code-switch constantly, and the batch
        // lane has hinted both since day one. Hints bias
        // recognition, they don't force a language.
        var hints = Set(["en", "zh"])
        if let t = translation {
            switch t.type {
            case "one_way":
                if let target = t.target_language { hints.insert(target) }
            case "two_way":
                if let a = t.language_a { hints.insert(a) }
                if let b = t.language_b { hints.insert(b) }
            default:
                break
            }
        }
        return SonioxConfigMessage(
            model: "stt-rt-v6",
            audio_format: "pcm_s16le",
            sample_rate: AudioFormat.sampleRateHz,
            num_channels: 1,
            language_hints: Array(hints),
            enable_speaker_diarization: true,
            enable_language_identification: true,
            translation: translation,
            context: context
        )
    }
}

public struct SonioxTranscriptMessage: Decodable {
    public let tokens: [RawToken]?
    public let error_code: Int?
    public let error_message: String?

    public struct RawToken: Decodable {
        let text: String
        let start_ms: Int?
        let end_ms: Int?
        let speaker: String?
        let confidence: Double?
        let is_final: Bool?
        let translation_status: String?
        let language: String?
        let source_language: String?

        public func toSonioxWord() -> SonioxWord {
            SonioxWord(
                text: text,
                startMs: start_ms ?? 0,
                endMs: end_ms ?? 0,
                speaker: Int(speaker ?? "0") ?? 0,
                confidence: confidence ?? 1.0,
                isFinal: is_final ?? false,
                translationStatus: translation_status ?? "none",
                language: language,
                sourceLanguage: source_language
            )
        }
    }
}
