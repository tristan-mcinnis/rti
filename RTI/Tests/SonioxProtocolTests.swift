import RTICore
import XCTest

final class SonioxProtocolTests: XCTestCase {
    private func defaultConfigJSON() throws -> [String: Any] {
        let data = try JSONEncoder().encode(SonioxConfigMessage.default())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
