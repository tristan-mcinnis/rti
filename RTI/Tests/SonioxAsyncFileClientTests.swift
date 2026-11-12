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
        init(_ method: String, _ path: String, _ status: Int, _ text: String = "") {
            self.method = method
            self.path = path
            self.status = status
            body = Data(text.utf8)
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

    func testRawBytesSurviveFailedRemoteCleanupAndRetryOnlyDeletes() async throws {
        let (dir, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var steps = Self.submitted + [Self.status("completed"), Self.result, Self.cleanup[0]]
        steps += Array(repeating: Step("DELETE", "files/" + Self.file, 503), count: 3)
        do {
            _ = try await client(Transport(steps)).transcript(audio: audio, in: dir, sessionID: "demo", leg: .system, labels: true, context: nil)
            XCTFail("Expected cleanup failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("soniox-async-system.json")), Self.raw)
        let final = try await client(Transport([Self.cleanup[1]])).transcript(audio: audio, in: dir, sessionID: "demo", leg: .system, labels: true, context: nil)
        XCTAssertEqual(final, Self.raw)
    }
}
