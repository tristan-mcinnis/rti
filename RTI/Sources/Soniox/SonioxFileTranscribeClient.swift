import Foundation

/// Soniox async (file-based) transcription client. Used by the Regenerate
/// Transcript flow to produce a high-fidelity transcript from a recorded WAV
/// after the meeting ends. Uses the same v1 REST surface documented at
/// https://soniox.com/docs (Files → Transcriptions → poll → fetch transcript).
struct SonioxFileTranscript {
    let words: [SonioxWord]
}

enum SonioxFileTranscribeError: Error, LocalizedError {
    case invalidResponse
    case http(Int, String)
    case timedOut
    case cancelled
    case missingTranscript

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Soniox returned an unexpected response shape."
        case .http(let code, let body): return "Soniox HTTP \(code): \(body.prefix(200))"
        case .timedOut: return "Soniox transcription timed out."
        case .cancelled: return "Cancelled."
        case .missingTranscript: return "Soniox returned no transcript words."
        }
    }
}

actor SonioxFileTranscribeClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    init(apiKey: String, baseURL: URL = URL(string: "https://api.soniox.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func transcribe(
        wavURL: URL,
        languageHints: [String] = ["en"],
        maxSpeakers: Int = 4,
        pollInterval: TimeInterval = 2.0,
        timeout: TimeInterval = 600
    ) async throws -> SonioxFileTranscript {
        let fileId = try await uploadFile(wavURL: wavURL)
        let transcriptionId = try await createTranscription(
            fileId: fileId,
            languageHints: languageHints,
            maxSpeakers: maxSpeakers
        )
        try await waitForCompletion(transcriptionId: transcriptionId, pollInterval: pollInterval, timeout: timeout)
        return try await fetchTranscript(transcriptionId: transcriptionId)
    }

    // MARK: - REST plumbing

    private func uploadFile(wavURL: URL) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/files"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "----RTI-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: wavURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(wavURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        try Self.ensureOK(data: data, response: response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SonioxFileTranscribeError.invalidResponse
        }
        return id
    }

    private func createTranscription(fileId: String, languageHints: [String], maxSpeakers: Int) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "file_id": fileId,
            "model": "stt-async-preview",
            "language_hints": languageHints,
            "enable_speaker_diarization": true,
            "speaker_diarization_max_speakers": maxSpeakers
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        try Self.ensureOK(data: data, response: response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SonioxFileTranscribeError.invalidResponse
        }
        return id
    }

    private func waitForCompletion(transcriptionId: String, pollInterval: TimeInterval, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await fetchStatus(transcriptionId: transcriptionId)
            switch status {
            case "completed":
                return
            case "error":
                throw SonioxFileTranscribeError.http(500, "Soniox reported an error processing the file")
            default:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        throw SonioxFileTranscribeError.timedOut
    }

    private func fetchStatus(transcriptionId: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions/\(transcriptionId)"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        try Self.ensureOK(data: data, response: response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            throw SonioxFileTranscribeError.invalidResponse
        }
        return status
    }

    private func fetchTranscript(transcriptionId: String) async throws -> SonioxFileTranscript {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions/\(transcriptionId)/transcript"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        try Self.ensureOK(data: data, response: response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SonioxFileTranscribeError.invalidResponse
        }

        guard let tokensRaw = json["tokens"] as? [[String: Any]] else {
            throw SonioxFileTranscribeError.missingTranscript
        }
        let words: [SonioxWord] = tokensRaw.compactMap { dict -> SonioxWord? in
            guard let text = dict["text"] as? String else { return nil }
            let startMs = (dict["start_ms"] as? Int) ?? 0
            let endMs = (dict["end_ms"] as? Int) ?? startMs
            let speaker: Int = {
                if let s = dict["speaker"] as? Int { return s }
                if let s = dict["speaker"] as? String { return Int(s) ?? 0 }
                return 0
            }()
            let confidence = (dict["confidence"] as? Double) ?? 1.0
            return SonioxWord(
                text: text,
                startMs: startMs,
                endMs: endMs,
                speaker: speaker,
                confidence: confidence,
                isFinal: true
            )
        }
        return SonioxFileTranscript(words: words)
    }

    private static func ensureOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SonioxFileTranscribeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SonioxFileTranscribeError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
