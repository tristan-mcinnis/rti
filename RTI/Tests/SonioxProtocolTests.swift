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

    func test_defaultConfigUsesV6ModelAndCarriesNoKey() throws {
        let json = try defaultConfigJSON()

        XCTAssertEqual(json["model"] as? String, "stt-rt-v6")
        XCTAssertNil(json["api_key"], "the key travels in the Authorization header")
    }
}
