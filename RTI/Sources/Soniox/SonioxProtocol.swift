import Foundation

struct SonioxWord {
    let text: String
    let startMs: Int
    let endMs: Int
    let speaker: Int
    let confidence: Double
    let isFinal: Bool
}

struct SonioxConfigMessage: Codable {
    let api_key: String
    let model: String
    let audio_format: String
    let sample_rate: Int
    let num_channels: Int
    let language_hints: [String]
    let enable_speaker_diarization: Bool
    let speaker_diarization_max_speakers: Int

    static func `default`(apiKey: String) -> SonioxConfigMessage {
        SonioxConfigMessage(
            api_key: apiKey,
            model: "stt-rt-v4",
            audio_format: "pcm_s16le",
            sample_rate: 16_000,
            num_channels: 1,
            language_hints: ["en"],
            enable_speaker_diarization: true,
            speaker_diarization_max_speakers: 4
        )
    }
}

struct SonioxTranscriptMessage: Decodable {
    let tokens: [RawToken]?
    let error_code: Int?
    let error_message: String?

    struct RawToken: Decodable {
        let text: String
        let start_ms: Int?
        let end_ms: Int?
        let speaker: String?
        let confidence: Double?
        let is_final: Bool?

        func toSonioxWord() -> SonioxWord {
            SonioxWord(
                text: text,
                startMs: start_ms ?? 0,
                endMs: end_ms ?? 0,
                speaker: Int(speaker ?? "0") ?? 0,
                confidence: confidence ?? 1.0,
                isFinal: is_final ?? false
            )
        }
    }
}
