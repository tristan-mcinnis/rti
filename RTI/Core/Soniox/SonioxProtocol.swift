import Foundation

/// Exact fields of a Soniox token. The numeric accessors exist for older
/// rendering callers; the optional provider fields are the transcript evidence.
public struct SonioxWord: Sendable, Equatable, Codable {
    public let text: String
    public let providerStartMs: Int?
    public let providerEndMs: Int?
    public let providerSpeaker: String?
    public let providerConfidence: Double?
    public let providerIsFinal: Bool?
    public let providerTranslationStatus: String?
    public let language: String?
    public let sourceLanguage: String?

    private enum CodingKeys: String, CodingKey {
        case text, language
        case providerStartMs = "start_ms"
        case providerEndMs = "end_ms"
        case providerSpeaker = "speaker"
        case providerConfidence = "confidence"
        case providerIsFinal = "is_final"
        case providerTranslationStatus = "translation_status"
        case sourceLanguage = "source_language"
    }

    public var startMs: Int { providerStartMs ?? 0 }
    public var endMs: Int { providerEndMs ?? 0 }
    public var speaker: Int { providerSpeaker.flatMap(Int.init) ?? 0 }
    public var confidence: Double? { providerConfidence }
    public var isFinal: Bool { providerIsFinal == true }
    public var translationStatus: String { providerTranslationStatus ?? "none" }
    public var isStreamBoundary: Bool { text == "<end>" || text == "<fin>" }

    public init(text: String, providerStartMs: Int?, providerEndMs: Int?, providerSpeaker: String?,
                providerConfidence: Double?, providerIsFinal: Bool?, providerTranslationStatus: String?,
                language: String?, sourceLanguage: String?) {
        self.text = text
        self.providerStartMs = providerStartMs
        self.providerEndMs = providerEndMs
        self.providerSpeaker = providerSpeaker
        self.providerConfidence = providerConfidence
        self.providerIsFinal = providerIsFinal
        self.providerTranslationStatus = providerTranslationStatus
        self.language = language
        self.sourceLanguage = sourceLanguage
    }

    public init(text: String, startMs: Int, endMs: Int, speaker: Int, confidence: Double, isFinal: Bool,
                translationStatus: String, language: String?, sourceLanguage: String?) {
        self.init(text: text, providerStartMs: startMs, providerEndMs: endMs,
                  providerSpeaker: speaker == 0 ? nil : String(speaker), providerConfidence: confidence,
                  providerIsFinal: isFinal, providerTranslationStatus: translationStatus,
                  language: language, sourceLanguage: sourceLanguage)
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

    public static func `default`(translation: TranslationConfig? = nil, context: SonioxContext? = nil, diarize: Bool = true) -> SonioxConfigMessage {
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
            enable_speaker_diarization: diarize,
            enable_language_identification: true,
            translation: translation,
            context: context
        )
    }
}

public struct SonioxTranscriptMessage: Decodable {
    public let tokens: [SonioxWord]?
    public let error_code: Int?
    public let error_message: String?

}


/// Converts the local file adapter's token JSON into timestamped input for the
/// existing two-leg merger. Unlabelled utterances retain their actual offsets.
public enum SonioxFileTranscript {
    public static func timedText(data: Data, system: Bool, policy: SessionSpeakerPolicy) throws -> String {
        let reply = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: data)
        guard let tokens = reply.tokens else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var lines: [String] = []
        var text = ""
        var label = ""
        var startMs = 0
        var previousEnd = 0
        func flush() {
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            let time = TimeFormat.elapsedMs(startMs) + String(format: ".%03d", max(0, startMs) % 1000)
            lines.append("[\(time)] \(label): \(spoken)")
        }
        for word in tokens {
            guard word.translationStatus != "translation", !word.text.isEmpty, !word.isStreamBoundary else { continue }
            let speaker: String
            if !system { speaker = "Me" }
            else if policy.labelsEnabled, let raw = word.providerSpeaker, !raw.isEmpty { speaker = "Speaker \(raw)" }
            else { speaker = "Them" }
            let time = word.providerStartMs ?? previousEnd
            if text.isEmpty || label != speaker || time - previousEnd > 1500 ||
                time - startMs > 20000 || text.last.map({ "。！？.!?".contains($0) }) == true {
                flush()
                text = ""
                startMs = time
                label = speaker
            }
            text += word.text
            previousEnd = max(time, word.providerEndMs ?? time)
        }
        flush()
        return lines.joined(separator: "\n")
    }
}
