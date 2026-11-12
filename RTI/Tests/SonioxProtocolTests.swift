import RTICore
import XCTest

final class SonioxProtocolTests: XCTestCase {
    func testOriginalProviderJournalPreservesFinalTokensAcrossIndependentStreams() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try SonioxLiveJournal(directory: dir) { error in XCTFail(error) }
        let response = Data(#"{"tokens":[{"text":" 我","is_final":true,"start_ms":20,"end_ms":50,"speaker":"7"},{"text":"，","is_final":true},{"text":"猜","is_final":false}]}"#.utf8)
        let packet = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: response)
        let words = try XCTUnwrap(packet.tokens)
        journal.append(words, leg: "system", stream: "one", baseMs: 0)
        journal.append(words, leg: "mic", stream: "two", baseMs: 4500)
        try journal.close()
        let url = dir.appendingPathComponent(SonioxLiveJournal.filename)
        let batches = try Data(contentsOf: url).split(separator: 10).map {
            try JSONDecoder().decode(SonioxLiveJournal.Batch.self, from: Data($0))
        }
        XCTAssertEqual(batches.map(\.leg), ["system", "mic"])
        XCTAssertEqual(batches.map(\.stream), ["one", "two"])
        XCTAssertEqual(batches.map(\.baseMs), [0, 4500])
        for batch in batches {
            XCTAssertEqual(batch.tokens.map(\.text), [" 我", "，"])
            XCTAssertEqual(batch.tokens.first?.providerSpeaker, "7")
            XCTAssertNil(batch.tokens.last?.providerSpeaker)
            XCTAssertNil(batch.tokens.last?.providerStartMs)
            XCTAssertNil(batch.tokens.first?.providerConfidence)
        }
        XCTAssertThrowsError(try SonioxLiveJournal(directory: dir) { _ in })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    private func defaultConfigJSON() throws -> [String: Any] {
        let data = try JSONEncoder().encode(SonioxConfigMessage.default())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMicAndAnonymousFileTurnRetainProviderTimeWithoutDiarization() throws {
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SonioxConfigMessage.default(diarize: false))) as? [String: Any]
        XCTAssertEqual(wire?["enable_speaker_diarization"] as? Bool, false)
        let data = Data(#"{"tokens":[{"text":"很轻。","speaker":"2","start_ms":1250,"end_ms":1400}]}"#.utf8)
        let anonymous = SessionSpeakerPolicy(labelsEnabled: false, expectedCount: 4)
        XCTAssertEqual(try SonioxFileTranscript.timedText(data: data, system: true, policy: anonymous), "[0:01.250] Them: 很轻。")
        XCTAssertEqual(try SonioxFileTranscript.timedText(data: data, system: false, policy: .init()), "[0:01.250] Me: 很轻。")
        XCTAssertEqual(try SonioxFileTranscript.timedText(data: data, system: true, policy: .init()), "[0:01.250] Speaker 2: 很轻。")
    }

    func test_defaultConfigUsesOnlyCurrentDiarizationField() throws {
        let json = try defaultConfigJSON()

        XCTAssertEqual(json["enable_speaker_diarization"] as? Bool, true)
        XCTAssertNil(
            json["speaker_diarization_max_speakers"],
            "the current Soniox WebSocket API does not document this legacy field"
        )
    }

    func test_defaultConfigAsksForLanguageLabelsAndCarriesContext() throws {
        let context = SonioxContext.forMeeting(
            callType: "Research", project: nil, meetingTitle: nil, participants: [], terms: ["Qorvane"]
        )
        let data = try JSONEncoder().encode(SonioxConfigMessage.default(context: context))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["enable_language_identification"] as? Bool, true)
        let sent = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(sent["terms"] as? [String], ["Qorvane"])
        XCTAssertEqual((sent["general"] as? [[String: String]])?.first, ["key": "Setting", "value": "Research"])
    }

    func test_meetingContextNamesTheCallAndSkipsEmptyFactsAndEmails() {
        let context = SonioxContext.forMeeting(
            callType: "Client call",
            project: "  Qorvane study ",
            meetingTitle: "",
            participants: ["Ana Ruiz", "ana ruiz", "room@example.com", " "],
            terms: ["Qorvane", "qorvane", ""]
        )

        XCTAssertEqual(context.general.map(\.key), ["Setting", "Project", "Participants"])
        XCTAssertEqual(context.general[1].value, "Qorvane study")
        XCTAssertEqual(context.general[2].value, "Ana Ruiz")
        XCTAssertEqual(context.terms, ["Qorvane"])
    }

    func test_meetingContextStaysUnderSonioxLimitWhenTheTermsFileIsHuge() throws {
        let terms = (0 ..< 5_000).map { "品牌名称术语\($0)" }
        let context = SonioxContext.forMeeting(
            callType: "Research", project: "Study", meetingTitle: nil, participants: [], terms: terms
        )

        let data = try JSONEncoder().encode(context)
        XCTAssertLessThanOrEqual(String(decoding: data, as: UTF8.self).count, 4_000)
        XCTAssertEqual(context.terms?.first, terms[0])
    }

    func test_termsFileSkipsBlanksAndComments() {
        XCTAssertEqual(
            SonioxContext.terms(inFile: "# brands\nQorvane\n\n  Lumora Labs  \n"),
            ["Qorvane", "Lumora Labs"]
        )
    }

    func test_oldSessionFilesDecodeWithoutContext_andNewOnesKeepIt() throws {
        let old = #"{"sessionId":"a","mode":"Research"}"#
        XCTAssertNil(try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(old.utf8)).speechContext)

        let context = SonioxContext.forMeeting(
            callType: "Research", project: nil, meetingTitle: nil, participants: [], terms: ["Qorvane"]
        )
        let metadata = SessionArchiveMetadata(
            sessionId: "a", systemAudioStartOffsetMs: nil, micAudioFile: nil, systemAudioFile: nil,
            mode: nil, workstream: nil, durationSeconds: nil, speechContext: context
        )
        let decoded = try JSONDecoder().decode(SessionArchiveMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded.speechContext, context)
    }

    func test_defaultConfigUsesV6ModelAndCarriesNoKey() throws {
        let json = try defaultConfigJSON()

        XCTAssertEqual(json["model"] as? String, "stt-rt-v6")
        XCTAssertNil(json["api_key"], "the key travels in the Authorization header")
    }
}
