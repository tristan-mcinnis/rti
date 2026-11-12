import Foundation
import RTICore
import XCTest

final class GuideSpeakerArchiveTests: XCTestCase {
    func testLegacyRawAndDisplayLabelFilesRoundTripAsTheExistingFlatMapping() throws {
        let file = Data(#"{"remote_2":"Pip","Room speaker 1":"Robin","self":"Mic wearer"}"#.utf8)
        let archive = try JSONDecoder().decode(SpeakerNameArchive.self, from: file)
        XCTAssertEqual(archive.names, ["remote_2": "Pip", "room_1": "Robin"])
        let roundTrip = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(roundTrip, ["Remote speaker 2": "Pip", "Room speaker 1": "Robin"])
    }

    func testGuideMappingKeepsCustomNameSeatAndModeratorWithoutFreeTextConversion() throws {
        let seat = GuideSeat(seat: 3, label: "P3", segment: "U")
        let original = SpeakerNameArchive(
            names: ["remote_1": "Aster", "remote_3": "Birch"],
            assignments: [
                "remote_1": GuideSpeakerAssignment(seat: seat),
                "remote_2": GuideSpeakerAssignment(isModerator: true),
            ]
        )
        let restored = try JSONDecoder().decode(SpeakerNameArchive.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.displayNames["Remote speaker 1"], "P3")
        XCTAssertEqual(restored.names["remote_1"], "Aster")
        XCTAssertEqual(restored.guideSpeakers["remote_1"]?.seatCode, "3U")
        XCTAssertEqual(restored.guideSpeakers["remote_1"]?.participant, "P3")
        XCTAssertEqual(restored.guideSpeakers["remote_2"]?.isModerator, true)
        XCTAssertEqual(restored.guideSpeakers["remote_3"]?.participant, "Birch")
    }

    func testJSONAndQuotedCSVWithReorderedColumnsLoadTheSameRoster() throws {
        let csv = Data("\u{feff}segment,label,seat\r\nu,\"用户, One\",3\r\nC,\"A \"\"B\"\"\",6\r\n".utf8)
        let json = Data(#"[{"seat":3,"label":"用户, One","segment":"U"},{"seat":6,"label":"A \"B\"","segment":"C"}]"#.utf8)
        XCTAssertEqual(try GuideRoster.parse(csv, fileExtension: "CSV"), try GuideRoster.parse(json, fileExtension: "json"))
    }

    func testInvalidOrDuplicateSeatFailsWithoutPartialRoster() {
        for csv in [
            "seat,label,segment\n1,A,U\n1,B,L",
            "seat,label,segment\n0,A,U",
            "seat,label,segment\n1,A,Z",
            "seat,label,segment\n1,,U",
            "seat,label,segment\n1,\"unterminated",
        ] {
            XCTAssertThrowsError(try GuideRoster.parse(Data(csv.utf8), fileExtension: "csv"))
        }
    }
}
