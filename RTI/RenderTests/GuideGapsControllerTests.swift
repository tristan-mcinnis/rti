import RTICore
import XCTest

/// The controller's gaps wiring: furthest progress, the current question, a manual
/// jump back, evidence filed live, and the empty result after the session ends.
@MainActor
final class GuideGapsControllerTests: RenderProofTestCase {
    func testGapsFollowProgressJumpBackEvidenceAndSessionEnd() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        XCTAssertEqual(guide.questions.map(\.qid), ["S1Q1", "S1Q2", "S2Q1"])
        let controller = GuideSessionController()
        XCTAssertTrue(controller.gaps.isEmpty)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        controller.start(sessionID: "gaps-fixture", guide: guide, guideURL: url, group: nil, roster: [], rosterURL: nil, startedAt: start)
        XCTAssertTrue(controller.gaps.isEmpty, "nothing is passed at the first question")

        controller.select("S2Q1", at: start.addingTimeInterval(20))
        XCTAssertEqual(controller.furthestIndex, 2)
        XCTAssertEqual(controller.gaps.map(\.qid), ["S1Q2", "S1Q1"])
        XCTAssertEqual(controller.gaps.map(\.detail), ["Skipped", "Skipped"])

        controller.select("S1Q1", at: start.addingTimeInterval(30))
        XCTAssertEqual(controller.currentQuestionID, "S1Q1")
        XCTAssertEqual(controller.furthestIndex, 2, "a jump back keeps the furthest progress")
        XCTAssertEqual(controller.gaps.map(\.qid), ["S1Q2"], "the question being asked again is not a gap")

        controller.select("S2Q1", at: start.addingTimeInterval(40))
        let reply = """
        {"suggestion":null,"evidence":[],"cells":[{"qid":"S1Q1","coverage":"Answered","summary":"Both carry it daily.",
        "turns":["a","b"],"quotes":[{"turn":"a","english":"Every day."},{"turn":"b","english":"On the commute."}],"votes":[]}]}
        """
        let pass = try XCTUnwrap(GuidePrompt.decode(reply))
        controller.fileEvidence(pass, from: [GuideTurn(id: "a", speaker: "remote", startMs: 2000, text: "每天都用。"),
                                             GuideTurn(id: "b", speaker: "remote", startMs: 6000, text: "On the commute.")])
        XCTAssertEqual(controller.extraction?.cells.first?.coverage, "Answered")
        XCTAssertEqual(controller.gaps.map(\.qid), ["S1Q2"])

        controller.endSession("gaps-fixture")
        XCTAssertTrue(controller.gaps.isEmpty)
        XCTAssertEqual(controller.furthestIndex, 0)
    }
}
