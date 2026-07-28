import RTICore
import XCTest

final class SonioxProtocolTests: XCTestCase {
    func test_defaultConfigUsesOnlyCurrentDiarizationField() throws {
        let config = SonioxConfigMessage.default(apiKey: "test-key")
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["enable_speaker_diarization"] as? Bool, true)
        XCTAssertNil(
            json["speaker_diarization_max_speakers"],
            "the current Soniox v5 WebSocket API does not document this legacy field"
        )
    }
}
