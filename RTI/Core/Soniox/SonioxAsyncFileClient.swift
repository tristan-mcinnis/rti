import Darwin
import Foundation

/// A session leg owns the exact HTTP result. Job state only records what is
/// needed to resume a paid request and clean up its two remote resources.
public struct SonioxAsyncFileClient: Sendable {
    public enum Leg: String, Sendable { case mic, system }
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? {
            message
        }
    }

    public typealias Send = @Sendable (URLRequest, URL?) async throws -> (Data, HTTPURLResponse)
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let key: String
    private let send: Send
    private let sleep: Sleep
    private let pollLimit: Int
    private static let base = URL(string: "https://api.soniox.com/v1")!

    public init(apiKey: String, pollLimit: Int = 1800, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                send: @escaping Send = SonioxAsyncFileClient.http)
    {
        key = apiKey
        self.pollLimit = max(1, pollLimit)
        self.sleep = sleep
        self.send = send
    }

    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public static func http(_ request: URLRequest, upload: URL?) async throws -> (Data, HTTPURLResponse) {
        let session = httpSession
        let result = if let upload {
            try await session.upload(for: request, fromFile: upload)
        } else {
            try await session.data(for: request)
        }
        guard let response = result.1 as? HTTPURLResponse else { throw Failure(message: "Soniox returned an invalid HTTP response.") }
        return (result.0, response)
    }

    private struct Job: Codable {
        let reference: String
        let audioName: String
        var fileID: UUID?
        var transcriptionID: UUID?
        var uploading = false
        var creating = false
        var terminalError: String?
        /// The audio this job uploaded. Nil in jobs saved before 2026-11-13.
        var audio: AudioStamp?
    }

    /// True for an error the Soniox service returned (an HTTP status, a bad
    /// or failed job), as opposed to a local file or network error.
    public static func isProviderError(_ error: Error) -> Bool {
        error is Failure || error is HTTPFailure
    }

    /// The audio a raw transcript was made from, by byte size. A raw file
    /// whose stamp no longer matches the audio (the WAV grew after an
    /// upgrade of a recording in progress) is stale. Size alone, so a copied
    /// or restored session folder keeps its paid result.
    private struct AudioStamp: Codable, Equatable {
        let bytes: Int64

        init?(_ audio: URL) {
            // Read the file, not URL resource values: a URL caches those, and
            // the same URL is passed again after the file grew.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            bytes = size
        }
    }

    private struct HTTPFailure: LocalizedError {
        let status: Int
        let method: String
        var errorDescription: String? {
            "Soniox " + method + " failed (HTTP " + String(status) + ")."
        }
    }

    private struct Remote: Decodable {
        let id: UUID
        let status: String?
        let error_type: String?
        let client_reference_id: String?
    }

    private struct ListPage: Decodable {
        let files: [Remote]?
        let transcriptions: [Remote]?
        let next_page_cursor: String?
    }

    private struct Create: Encodable {
        let model = "stt-async-v6"
        let language_hints: [String]
        let enable_language_identification = true
        let enable_speaker_diarization: Bool
        let context: SonioxContext?
        let file_id: String
        let client_reference_id: String
    }

    public func transcript(audio: URL, in directory: URL, sessionID: String, leg: Leg,
                           labels: Bool, languageHints: [String] = ["en", "zh"], context: SonioxContext?) async throws -> Data
    {
        let raw = directory.appendingPathComponent("soniox-async-\(leg.rawValue).json")
        let checkpoint = directory.appendingPathComponent(".soniox-async-\(leg.rawValue)-job.json")
        let stampURL = directory.appendingPathComponent(".soniox-async-\(leg.rawValue)-audio.json")
        let manager = FileManager.default
        let currentAudio = AudioStamp(audio)
        var job: Job
        if manager.fileExists(atPath: checkpoint.path) {
            job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: checkpoint))
            guard job.audioName == audio.lastPathComponent else { throw Failure(message: "The saved Soniox job belongs to another audio file.") }
        } else {
            job = Job(reference: "\(sessionID)/\(leg.rawValue)/\(UUID().uuidString)", audioName: audio.lastPathComponent)
        }
        // A raw result or a job made from an earlier, shorter copy of this
        // audio would stand in for the whole recording forever. Set it aside
        // and transcribe the audio as it is now.
        let savedStamp = (try? Data(contentsOf: stampURL)).flatMap { try? JSONDecoder().decode(AudioStamp.self, from: $0) }
        let rawIsStale = manager.fileExists(atPath: raw.path) && savedStamp != nil && savedStamp != currentAudio
        let jobIsStale = job.audio != nil && job.audio != currentAudio && job.terminalError == nil
        if rawIsStale || jobIsStale {
            if manager.fileExists(atPath: checkpoint.path) {
                await bestEffortCleanup(job: &job, at: checkpoint)
            }
            if rawIsStale {
                let aside = directory.appendingPathComponent(".soniox-async-\(leg.rawValue)-stale.json")
                try? manager.removeItem(at: aside)
                try manager.moveItem(at: raw, to: aside)
            }
            job = Job(reference: "\(sessionID)/\(leg.rawValue)/\(UUID().uuidString)", audioName: audio.lastPathComponent)
        }
        // A killed upload can leave a temporary multipart body. Its filename
        // belongs to this persisted job and a single per-session upgrade.
        if let leftover = Self.multipartURL(reference: job.reference), manager.fileExists(atPath: leftover.path) {
            try manager.removeItem(at: leftover)
        }
        if manager.fileExists(atPath: raw.path) {
            let result = try Data(contentsOf: raw)
            try Self.validate(result, jobID: job.transcriptionID)
            if manager.fileExists(atPath: checkpoint.path) {
                await bestEffortCleanup(job: &job, at: checkpoint)
            }
            return result
        }
        if let error = job.terminalError {
            try await cleanup(job: &job, at: checkpoint)
            throw Failure(message: "Soniox could not transcribe this leg (\(error)).")
        }

        if job.fileID == nil {
            if job.uploading {
                job.fileID = try await locate(resource: "files", reference: job.reference)
            }
            if job.fileID == nil {
                job.uploading = true
                job.audio = currentAudio
                try Self.save(job, to: checkpoint)
                let upload = try await upload(audio, reference: job.reference)
                job.fileID = upload.id
            }
            job.uploading = false
            try Self.save(job, to: checkpoint)
        }
        guard let fileID = job.fileID else { throw Failure(message: "Soniox did not return an uploaded file ID.") }
        if job.transcriptionID == nil {
            if job.creating {
                job.transcriptionID = try await locate(resource: "transcriptions", reference: job.reference)
            }
            if job.transcriptionID == nil {
                job.creating = true
                try Self.save(job, to: checkpoint)
                var request = request("transcriptions", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(Create(language_hints: languageHints, enable_speaker_diarization: leg == .system && labels,
                                                                   context: context, file_id: fileID.uuidString, client_reference_id: job.reference))
                do {
                    let (data, _) = try await exchange(request)
                    job.transcriptionID = try JSONDecoder().decode(Remote.self, from: data).id
                } catch let error as HTTPFailure where error.status == 400 || error.status == 404 {
                    job.terminalError = "create rejected"
                    try Self.save(job, to: checkpoint)
                    try await cleanup(job: &job, at: checkpoint)
                    throw error
                }
            }
            job.creating = false
            try Self.save(job, to: checkpoint)
        }
        guard let jobID = job.transcriptionID else { throw Failure(message: "Soniox did not return a transcription ID.") }
        let path = "transcriptions/\(jobID.uuidString)"
        for attempt in 0 ..< pollLimit {
            let (bytes, response) = try await exchange(request(path), allowMissing: true)
            if response.statusCode == 404 {
                job.terminalError = "expired job"
                job.transcriptionID = nil
                try Self.save(job, to: checkpoint)
                try await cleanup(job: &job, at: checkpoint)
                throw Failure(message: "The stored Soniox job expired. The retained audio is available for retry.")
            }
            let status = try JSONDecoder().decode(Remote.self, from: bytes)
            guard status.id == jobID else { throw Failure(message: "Soniox returned the status for a different transcription.") }
            switch status.status {
            case "queued", "processing":
                if attempt + 1 < pollLimit {
                    try await sleep(.seconds(2))
                }
            case "completed":
                let (bytes, _) = try await exchange(request(path + "/transcript"))
                try Self.validate(bytes, jobID: jobID)
                // The stamp goes first: a raw file never exists without the
                // audio it describes once this version wrote it.
                if let stamp = job.audio ?? currentAudio {
                    try Self.atomic(JSONEncoder().encode(stamp), to: stampURL)
                }
                try Self.atomic(bytes, to: raw)
                // The transcript is saved. A failed remote delete keeps the
                // job file, so a later run deletes the leftovers; it never
                // fails this run.
                await bestEffortCleanup(job: &job, at: checkpoint)
                return bytes
            case "error":
                job.terminalError = status.error_type ?? "provider error"
                try Self.save(job, to: checkpoint)
                try await cleanup(job: &job, at: checkpoint)
                throw Failure(message: "Soniox could not transcribe this leg (\(job.terminalError ?? "provider error")).")
            default:
                throw Failure(message: "Soniox returned an unknown transcription state. Its job is saved for retry.")
            }
        }
        throw Failure(message: "Soniox is still processing the leg. Retry will resume the existing job.")
    }

    private func locate(resource: String, reference: String) async throws -> UUID? {
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var req = request(resource)
            if let cursor {
                req.url = req.url?.appending(queryItems: [.init(name: "cursor", value: cursor)])
            }
            let (data, _) = try await exchange(req)
            let page = try JSONDecoder().decode(ListPage.self, from: data)
            guard let items = resource == "files" ? page.files : page.transcriptions else {
                throw Failure(message: "Soniox returned an invalid job recovery page.")
            }
            if let match = items.first(where: { $0.client_reference_id == reference }) {
                return match.id
            }
            cursor = page.next_page_cursor
            if let cursor, !seen.insert(cursor).inserted {
                throw Failure(message: "Soniox repeated a recovery cursor.")
            }
        } while cursor != nil
        return nil
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return request
    }

    /// The request never left the Mac, so even a POST is safe to send again.
    static let unsentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost]
    /// The request may have reached Soniox: replay only a GET or DELETE. A
    /// POST is resumed from the job file by the next run instead.
    static let interruptedCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost]

    private func exchange(_ request: URLRequest, upload: URL? = nil, allowMissing: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let replayable = request.httpMethod != "POST"
        for attempt in 0 ... 2 {
            try Task.checkCancellation()
            let result: (Data, HTTPURLResponse)
            do { result = try await send(request, upload) }
            catch let error as URLError where attempt < 2
                && (Self.unsentCodes.contains(error.code) || (replayable && Self.interruptedCodes.contains(error.code)))
            {
                try await sleep(.seconds(2 << attempt))
                continue
            }
            let status = result.1.statusCode
            if (200 ..< 300).contains(status) || (allowMissing && status == 404) {
                return result
            }
            if replayable, attempt < 2, status == 429 || (500 ... 599).contains(status) {
                let delay = result.1.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? (2 << attempt)
                try await sleep(.seconds(max(1, min(delay, 120))))
                continue
            }
            throw HTTPFailure(status: status, method: request.httpMethod ?? "request")
        }
        throw Failure(message: "Soniox could not complete the request.")
    }

    /// Cleanup after the transcript is saved locally: a failure is left for a
    /// later run (the job file stays) and never fails this one.
    private func bestEffortCleanup(job: inout Job, at checkpoint: URL) async {
        do { try await cleanup(job: &job, at: checkpoint) } catch {
            CoreLog.log("Soniox cleanup deferred to the next run: \(error.localizedDescription)", category: "archive")
        }
    }

    private func cleanup(job: inout Job, at checkpoint: URL) async throws {
        if let id = job.transcriptionID {
            _ = try await exchange(request("transcriptions/\(id.uuidString)", method: "DELETE"), allowMissing: true)
            job.transcriptionID = nil
            try Self.save(job, to: checkpoint)
        }
        if let id = job.fileID {
            _ = try await exchange(request("files/\(id.uuidString)", method: "DELETE"), allowMissing: true)
            job.fileID = nil
            try Self.save(job, to: checkpoint)
        }
        try FileManager.default.removeItem(at: checkpoint)
    }

    /// URLSession uploads from disk without retaining a multi-hour recording
    /// in RAM. Use an owner-only temporary multipart body until upload returns.
    private static func multipartURL(reference: String) -> URL? {
        guard let token = reference.split(separator: "/").last, let id = UUID(uuidString: String(token)) else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("rti-soniox-\(id.uuidString).multipart")
    }

    private func upload(_ audio: URL, reference: String) async throws -> Remote {
        let boundary = UUID().uuidString
        guard let temporary = Self.multipartURL(reference: reference) else { throw Failure(message: "Invalid local Soniox job reference.") }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"client_reference_id\"\r\n\r\n\(reference)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(audio.pathExtension == "wav" ? "wav" : "m4a")\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: audio)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        var req = request("files", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await exchange(req, upload: temporary)
        return try JSONDecoder().decode(Remote.self, from: data)
    }

    private static func validate(_ data: Data, jobID: UUID?) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = json["id"] as? String, let id = UUID(uuidString: rawID),
              jobID == nil || id == jobID, json["tokens"] is [Any], json["text"] is String
        else {
            throw Failure(message: "Soniox returned an invalid transcript. The saved job can be retried.")
        }
    }

    private static func save(_ job: Job, to file: URL) throws {
        try atomic(JSONEncoder().encode(job), to: file)
    }

    private static func atomic(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".soniox-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        try output.write(contentsOf: data)
        try output.synchronize()
        guard Darwin.rename(temp.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
