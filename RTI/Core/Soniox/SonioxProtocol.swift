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

/// Soniox `context` object. Biases recognition toward known terms. We only
/// populate `terms` (proper nouns from past meetings); `general`/`text` are
/// available in the API but unused here.
/// See https://soniox.com/docs/stt/concepts/context
struct SonioxContext: Codable {
    let terms: [String]
}

public struct SonioxConfigMessage: Codable {
    let api_key: String
    let model: String
    let audio_format: String
    let sample_rate: Int
    let num_channels: Int
    let language_hints: [String]
    let enable_speaker_diarization: Bool
    let speaker_diarization_max_speakers: Int
    let translation: TranslationConfig?
    let context: SonioxContext?

    public static func `default`(apiKey: String, translation: TranslationConfig? = nil, contextTerms: [String] = []) -> SonioxConfigMessage {
        var hints = Set(["en"])
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
            api_key: apiKey,
            model: "stt-rt-v4",
            audio_format: "pcm_s16le",
            sample_rate: 16_000,
            num_channels: 1,
            language_hints: Array(hints),
            enable_speaker_diarization: true,
            speaker_diarization_max_speakers: 8,
            translation: translation,
            context: contextTerms.isEmpty ? nil : SonioxContext(terms: contextTerms)
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
