import Foundation
import RTICore
import XCTest

final class SonioxAsyncFileClientTests: XCTestCase {
    private static let file = "00000000-0000-4000-8000-000000000001"
    private static let job = "00000000-0000-4000-8000-000000000002"
    private static let raw = Data("""
    { "id" : "\(job)", "text":"好", "future_field": {"x": true},
      "tokens": [{"text":"好","speaker":"desk-B","start_ms":201,"end_ms":259,"confidence":0.83}]
    }
    """.utf8)
    private struct Step: Sendable {
        let method: String, path: String, status: Int, body: Data
        /// Thrown instead of a response: the network fault for this request.
        var fault: URLError.Code?
        init(_ method: String, _ path: String, _ status: Int, _ text: String = "") {
            self.method = method
            self.path = path
            self.status = status
            body = Data(text.utf8)
        }

        static func failing(_ method: String, _ path: String, _ code: URLError.Code) -> Step {
            var step = Step(method, path, 0)
            step.fault = code
            return step
        }
    }

    private actor Transport {
        var steps: [Step]
        var upload: Data?
        var create: Data?
        var calls: [String] = []
        init(_ steps: [Step]) {
            self.steps = steps
        }

        func send(_ request: URLRequest, upload: URL?) throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, !steps.isEmpty else { throw URLError(.badURL) }
            let expected = steps.removeFirst()
            XCTAssertEqual(url.path.lowercased(), "/v1/" + expected.path.lowercased())
            XCTAssertEqual(request.httpMethod, expected.method)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer invented")
            calls.append(expected.method + " " + expected.path)
            if let fault = expected.fault { throw URLError(fault) }
            if let upload {
                self.upload = try Data(contentsOf: upload)
                XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: upload.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            if request.httpMethod == "POST", upload == nil {
                create = request.httpBody
            }
            return (expected.body, HTTPURLResponse(url: url, statusCode: expected.status, httpVersion: nil, headerFields: [:])!)
        }
    }

    private func fixture() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rti-async-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("audio.wav")
        try Data("INVENTED_AUDIO".utf8).write(to: audio)
        return (dir, audio)
    }

    private func client(_ transport: Transport, polls: Int = 3) -> SonioxAsyncFileClient {
        .init(apiKey: "invented", pollLimit: polls, sleep: { _ in }, send: { request, upload in try await transport.send(request, upload: upload) })
    }

    private static var submitted: [Step] {
        [Step("POST", "files", 201, "{\"id\":\"\(file)\"}"),
         Step("POST", "transcriptions", 201, "{\"id\":\"\(job)\",\"status\":\"queued\"}")]
    }

    private static func status(_ value: String) -> Step {
        Step("GET", "transcriptions/" + job, 200, "{\"id\":\"\(job)\",\"status\":\"\(value)\"}")
    }

    private static var result: Step {
        Step("GET", "transcriptions/\(job)/transcript", 200, String(decoding: raw, as: UTF8.self))
    }

    private static var cleanup: [Step] {
        [Step("DELETE", "transcriptions/" + job, 204), Step("DELETE", "files/" + file, 204)]
    }

    func testNativeRequestsAndExactRawBytesForBothLegs() async throws {
        for (leg, labels, expectsDiarization) in [(SonioxAsyncFileClient.Leg.mic, true, false), (.system, true, true), (.system, false, false)] {
            let (dir, audio) = try fixture()
            defer { try? FileManager.default.removeItem(at: dir) }
            let transport = Transport(Self.submitted + [Self.status("processing"), Self.status("completed"), Self.result] + Self.cleanup)
            let ctx = try JSONDecoder().decode(SonioxContext.self, from: Data(#"{"general":[{"key":"topic","value":"invented"}],"terms":["Mooncup"]}"#.utf8))
            let bytes = try await client(transport).transcript(audio: audio, in: dir, sessionID: "demo", leg: leg, labels: labels, context: ctx)
            let rawURL = dir.appendingPathComponent("soniox-async-" + leg.rawValue + ".json")
            XCTAssertEqual(bytes, Self.raw)
            XCTAssertEqual(try Data(contentsOf: rawURL), Self.raw)
            XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: rawURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let uploaded = await transport.upload
            let made = await transport.create
            let form = try String(decoding: XCTUnwrap(uploaded), as: UTF8.self)
            XCTAssertTrue(form.contains("name=\"client_reference_id\""))
            XCTAssertTrue(form.contains("demo/" + leg.rawValue + "/"))
            XCTAssertTrue(form.contains("INVENTED_AUDIO"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(made)) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "stt-async-v6")
            XCTAssertEqual(json["enable_speaker_diarization"] as? Bool, expectsDiarization)
            XCTAssertEqual(json["enable_language_identification"] as? Bool, true)
            XCTAssertEqual(json["language_hints"] as? [String], ["en", "zh"])
            XCTAssertEqual((json["context"] as? [String: Any])?["terms"] as? [String], ["Mooncup"])
            let remaining = await transport.steps.count
            XCTAssertEqual(remaining, 0)
            let emptyTransport = Transport([])
            let again = try await client(emptyTransport).transcript(audio: audio, in: dir, sessionID: "demo", leg: leg, labels: labels, context: nil)
            XCTAssertEqual(again, Self.raw)
        }
    }

    func testTimedOutJobResumesWithoutASecondUploadOrCreate() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = Transport(Self.submitted + [Self.status("queued")])
        do {
            _ = try await client(waiting, polls: 1).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
            XCTFail("The unfinished job completed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("resume")) }
        let resumed = Transport([Step("GET", "transcriptions/" + Self.job, 429), Self.status("completed"), Self.result] + Self.cleanup)
        let final = try await client(resumed).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        XCTAssertEqual(final, Self.raw)
        let calls = await resumed.calls
        XCTAssertFalse(calls.contains(where: { $0.hasPrefix("POST") }))
    }

    func testTerminalErrorCleansBothResourcesAndPreservesSpeechFiles() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = Transport(Self.submitted + [Self.status("error")] + Self.cleanup)
        do {
            _ = try await client(transport).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
            XCTFail("Provider failure was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not transcribe")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [audio.lastPathComponent])
        let count = await transport.steps.count
        XCTAssertEqual(count, 0)
    }

    func testRecoversAmbiguousCreateFromProviderReferenceWithoutASecondPaidRequest() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = "demo/mic/" + UUID().uuidString
        let partial: [String: Any] = ["reference": reference, "audioName": audio.lastPathComponent,
                                      "fileID": Self.file, "uploading": false, "creating": true]
        try JSONSerialization.data(withJSONObject: partial).write(to: dir.appendingPathComponent(".soniox-async-mic-job.json"))
        let listing: [String: Any] = ["transcriptions": [["id": Self.job, "client_reference_id": reference]]]
        let first = try Step("GET", "transcriptions", 200, String(decoding: JSONSerialization.data(withJSONObject: listing), as: UTF8.self))
        let transport = Transport([first, Self.status("completed"), Self.result] + Self.cleanup)
        let result = try await client(transport).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        XCTAssertEqual(result, Self.raw)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains(where: { $0.hasPrefix("POST") }))
    }

    /// NET-1: the transcript is saved, then the remote DELETE fails three
    /// times on a dropped connection. The run succeeds with the saved bytes;
    /// the job file stays, so the next run only deletes the leftovers.
    func testRawBytesSurviveFailedRemoteCleanupAndRetryOnlyDeletes() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var steps = Self.submitted + [Self.status("completed"), Self.result, Self.cleanup[0]]
        steps += Array(repeating: Step.failing("DELETE", "files/" + Self.file, .networkConnectionLost), count: 3)
        let transport = Transport(steps)
        let first = try await client(transport).transcript(audio: audio, in: dir, sessionID: "demo", leg: .system, labels: true, context: nil)
        XCTAssertEqual(first, Self.raw, "a failed cleanup after the transcript is saved must not fail the run")
        let left = await transport.steps.count
        XCTAssertEqual(left, 0)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("soniox-async-system.json")), Self.raw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".soniox-async-system-job.json").path))
        let retry = Transport([Self.cleanup[1]])
        let final = try await client(retry).transcript(audio: audio, in: dir, sessionID: "demo", leg: .system, labels: true, context: nil)
        XCTAssertEqual(final, Self.raw)
        let calls = await retry.calls
        XCTAssertEqual(calls, ["DELETE files/" + Self.file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".soniox-async-system-job.json").path))
    }

    /// NET-1: DNS fails right after Wi-Fi rejoins. The upload never left the
    /// Mac, so it is sent again and the run completes with one upload.
    func testUnsentUploadAndCreateAreSentAgainAfterDNSAndConnectFailures() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = Transport([
            .failing("POST", "files", .cannotFindHost),
            .failing("POST", "files", .notConnectedToInternet),
            Self.submitted[0],
            .failing("POST", "transcriptions", .cannotConnectToHost),
            Self.submitted[1],
            .failing("GET", "transcriptions/" + Self.job, .dnsLookupFailed),
            Self.status("completed"), Self.result,
        ] + Self.cleanup)
        let bytes = try await client(transport).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        XCTAssertEqual(bytes, Self.raw)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "POST files" }.count, 3)
        XCTAssertEqual(calls.filter { $0 == "POST transcriptions" }.count, 2)
        let left = await transport.steps.count
        XCTAssertEqual(left, 0)
    }

    /// A POST that may have reached Soniox (timed out mid-upload) is never
    /// blindly sent again; the next run finds it by its reference instead.
    func testInterruptedUploadIsNotReplayedButResumedByReference() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Transport([.failing("POST", "files", .timedOut)])
        do {
            _ = try await client(first).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
            XCTFail("an interrupted upload was replayed or ignored")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertFalse(SonioxAsyncFileClient.isProviderError(error), "a network fault is not a Soniox answer")
        }
        let job = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".soniox-async-mic-job.json"))) as? [String: Any]
        let reference = try XCTUnwrap(job?["reference"] as? String)
        let listing: [String: Any] = ["files": [["id": Self.file, "client_reference_id": reference]]]
        let found = try Step("GET", "files", 200, String(decoding: JSONSerialization.data(withJSONObject: listing), as: UTF8.self))
        let resumed = Transport([found, Self.submitted[1], Self.status("completed"), Self.result] + Self.cleanup)
        let bytes = try await client(resumed).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        XCTAssertEqual(bytes, Self.raw)
        let calls = await resumed.calls
        XCTAssertFalse(calls.contains("POST files"), "the upload Soniox already has is not paid for twice")
    }

    /// NET-2: a transcript cached while the WAV was still growing must not
    /// stand in for the finished recording. The grown audio is sent again
    /// and the stale result is set aside, not deleted.
    func testCachedTranscriptOfAShorterAudioIsSetAsideAndTheGrownAudioSent() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = Transport(Self.submitted + [Self.status("completed"), Self.result] + Self.cleanup)
        _ = try await client(partial).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        let unchanged = Transport([])
        let cached = try await client(unchanged).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        XCTAssertEqual(cached, Self.raw, "unchanged audio keeps using its saved transcript with no request")

        let handle = try FileHandle(forWritingTo: audio)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("_TEN_MORE_SECONDS".utf8))
        try handle.close()

        let full = Transport(Self.submitted + [Self.status("completed"), Self.result] + Self.cleanup)
        _ = try await client(full).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
        let calls = await full.calls
        XCTAssertTrue(calls.contains("POST files"), "the grown audio must be uploaded again")
        let body = await full.upload
        let uploaded = try String(decoding: XCTUnwrap(body), as: UTF8.self)
        XCTAssertTrue(uploaded.contains("INVENTED_AUDIO_TEN_MORE_SECONDS"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(".soniox-async-mic-stale.json")), Self.raw)
    }

    func testOnlySonioxAnswersCountAsProviderErrors() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for steps in [Self.submitted + [Self.status("error")] + Self.cleanup, [Step("POST", "files", 403)]] {
            do {
                _ = try await client(Transport(steps)).transcript(audio: audio, in: dir, sessionID: "demo", leg: .mic, labels: true, context: nil)
                XCTFail("the provider failure was accepted")
            } catch {
                XCTAssertTrue(SonioxAsyncFileClient.isProviderError(error), "\(error)")
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(".soniox-async-mic-job.json"))
        }
        XCTAssertFalse(SonioxAsyncFileClient.isProviderError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SonioxAsyncFileClient.isProviderError(CocoaError(.fileWriteOutOfSpace)))
    }
}
