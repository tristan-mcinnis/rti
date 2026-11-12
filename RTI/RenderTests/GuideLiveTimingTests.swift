import RTICore
import XCTest

@MainActor
final class GuideLiveTimingTests: RenderProofTestCase {
    func testLaterQuestionBeginsAtFreshEvidenceAndKeepsPreviousManualAssignment() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        let entries = [
            RenderFixtures.liveEntry("remote_1", "Earlier example.", 1000),
            RenderFixtures.liveEntry("remote_2", "It fits in my pocket.", 15000),
            RenderFixtures.liveEntry("self", "Now consider changing the lid.", 17000),
            RenderFixtures.liveEntry("remote_1", "I would change the lid.", 21000),
        ]
        let reply = """
        {"suggestion":"S2Q1","evidence":["remote_1@1000","self@17000","remote_1@21000"],"cells":[
        {"qid":"S2Q1","coverage":"Answered","summary":"Both mention the lid.","turns":["remote_2@15000","remote_1@21000"],
         "quotes":[{"turn":"remote_2@15000","english":"It fits in my pocket."},{"turn":"remote_1@21000","english":"I would change the lid."}],"votes":[]}]}
        """
        let request = LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: reply, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let controller = GuideSessionController(request: request)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        controller.start(sessionID: "clock-fixture", guide: guide, guideURL: url, group: nil, roster: [], rosterURL: nil, startedAt: start)
        controller.select("S1Q2", at: start.addingTimeInterval(10))
        await controller.finish(sessionId: "clock-fixture", entries: entries, at: start.addingTimeInterval(30))

        XCTAssertEqual(controller.currentQuestionID, "S2Q1")
        XCTAssertEqual(controller.elapsed(in: "S1", at: start.addingTimeInterval(30)), 17)
        XCTAssertEqual(controller.elapsed(in: "S2", at: start.addingTimeInterval(30)), 13)
        XCTAssertEqual(controller.extraction?.cells.last?.quotes.map(\.original), ["I would change the lid."])
        XCTAssertEqual(controller.extraction?.cells.first { $0.qid == "S1Q2" }?.quotes.map(\.original), ["It fits in my pocket."])
    }

    func testSingleFinalTurnAfterSilenceAndLateReplyAcrossSessions() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        let entries = [RenderFixtures.liveEntry("remote_1", "I chose the cup.", 7000)]
        let reply = """
        {"suggestion":null,"evidence":[],"cells":[{"qid":"S1Q1","coverage":"Answered","summary":"One respondent chose the cup.",
        "turns":["remote_1@7000"],"quotes":[{"turn":"remote_1@7000","english":"I chose the cup."}],"votes":[]}]}
        """
        let admission = LLMAdmissionController()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: reply, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: admission)
        let controller = GuideSessionController(request: request)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func startGroup(_ group: String) {
            controller.start(sessionID: group, guide: guide, guideURL: url, group: group, roster: [], rosterURL: nil, startedAt: start)
        }
        startGroup("G1")
        let held = await admission.acquireForeground()
        let stale = Task { @MainActor in
            await controller.generate(sessionId: "G1", entries: entries, at: start.addingTimeInterval(12))
        }
        for _ in 0 ..< 1000 {
            if controller.isGenerating {
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(controller.isGenerating)
        startGroup("G2")
        await admission.releaseForeground(held)
        let staleEnd = await stale.value
        XCTAssertNil(staleEnd)
        XCTAssertEqual(controller.extraction?.cells.first?.coverage, "Not covered")
        let currentEnd = await controller.generate(sessionId: "G2", entries: entries, at: start.addingTimeInterval(12))
        XCTAssertEqual(currentEnd, 7000)
        XCTAssertEqual(controller.extraction?.cells.first?.quotes.map(\.original), ["I chose the cup."])
    }

    func testPastSectionBoundaryOnlySubtractsPausesBeforeIt() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func date(_ second: Int) -> Date {
            start.addingTimeInterval(Double(second))
        }
        let pauses = [DateInterval(start: date(3), end: date(11)), DateInterval(start: date(30), end: date(40))]
        XCTAssertEqual(SessionCoordinator.capturedDuration(from: date(0), through: date(7), pauses: pauses, pausedAt: nil), 3)
        XCTAssertEqual(SessionCoordinator.capturedDuration(from: date(10), through: date(25), pauses: pauses, pausedAt: nil), 14)
        XCTAssertEqual(SessionCoordinator.capturedDuration(from: date(40), through: date(50), pauses: pauses, pausedAt: date(43)), 3)
    }
}
