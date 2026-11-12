import Foundation
import HouseDesign
import RTICore
import SwiftUI
import XCTest

final class GuideRenderProofTests: RenderProofTestCase {
    private let json = """
    {"title":"Storage habits","sections":[
      {"id":"S1","title":"Everyday storage","minutes":12,"questions":[
        {"qid":"S1Q1","en":"Where do you keep the things you use every day?","zh":"你把日常用品放在哪里？","must_ask":true,"probes":[]},
        {"qid":"S1Q2","en":"What makes an item hard to find?","zh":"什么东西最难找到？","must_ask":true,
         "probes":[{"en":"Think of yesterday.","zh":"回想一下昨天。"}]}]},
      {"id":"S2","title":"A recent change","minutes":3,"questions":[
        {"qid":"S2Q1","en":"What have you moved recently?","zh":"最近移动过哪些东西？","probes":[]}]}
    ]}
    """

    func testGuideInBothAppearances() throws {
        let guide = try GuideDocument.parse(Data(json.utf8))
        let pass = try JSONDecoder().decode(GuidePass.self, from: Data("""
        {"evidence":[],"cells":[{"qid":"S1Q1","coverage":"Answered",
        "summary":"One respondent keeps a key in a side pocket. The same pocket is used every day.",
        "turns":["t1"],"quotes":[{"turn":"t1","english":"I put it in the side pocket every day."}],"votes":[]}]}
        """.utf8))
        var extraction = GuideExtraction(group: "G1", transcript: "transcript.live.md", guide: guide)
        extraction.apply(pass, turns: [GuideTurn(id: "t1", speaker: "remote_1", startMs: 18000, text: "我每天都放在侧袋里。")],
                         speakers: ["remote_1": GuideSpeaker(participant: "P2")], rosterBase: nil)
        XCTAssertEqual(extraction.cells.first?.quotes.first?.original, "我每天都放在侧袋里。")
        try renderBothAppearances(
            name: "guide-live", size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440),
            view: GuideReadingView(guide: guide, currentID: "S1Q2", cells: extraction.cells,
                                   elapsed: { section, _ in section == "S1" ? 65 : 0 }, jump: { _ in })
                .padding(House.Spacing.sm).background(House.ColorToken.surfaceRaised)
        )
    }

    func testQuestionPaletteUsesTheLiveGuideAndEndsWithTheCall() throws {
        let guide = try GuideDocument.parse(Data(json.utf8))
        let controller = GuideSessionController.shared
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        let sessionID = try XCTUnwrap(session.currentSessionId)
        controller.start(sessionID: sessionID, guide: guide, guideURL: URL(fileURLWithPath: "/fixture/dg-questions.json"),
                         group: "G1", roster: [], rosterURL: nil)
        defer {
            controller.endSession(sessionID)
            session.endTranscriptReplayForProof()
        }
        let commands = CommandBuilder.guideCommands()
        let matches = CommandRegistry.matching(commands, query: "最近移动")
        XCTAssertEqual(matches.first?.id, "guide.question.S2Q1")
        matches.first?.perform()
        XCTAssertEqual(controller.currentQuestionID, "S2Q1")
        controller.move(by: -1)
        XCTAssertEqual(controller.currentQuestionID, "S1Q2")
        controller.endSession(sessionID)
        XCTAssertTrue(CommandBuilder.guideCommands().isEmpty)
        XCTAssertEqual(OverlayTab.notes.title, "Notes")
    }

    func testProjectGuideAndPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("06-discussion-guide/grid")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("dg-questions.json")
        try Data(json.utf8).write(to: source)
        let (guide, url) = try await GuideFileReader.shared.readGuide(at: root)
        XCTAssertEqual(url.standardizedFileURL, source.standardizedFileURL)

        let prep = GuidePreparation()
        prep.setGuide(guide, url: url)
        prep.groupText = " g2 "
        XCTAssertEqual(prep.group, "G2")
        try renderBothAppearances(
            name: "guide-prepare", size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 165),
            view: GuidePrepareControls(project: nil, preparation: prep)
                .padding(House.Spacing.sm).background(House.ColorToken.surfaceRaised)
        )
        prep.reset()
        XCTAssertNil(prep.guide)
        XCTAssertNil(prep.group)

        let other = root.appendingPathComponent("06-discussion-guide/backup")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: other.appendingPathComponent("dg-questions.json"))
        do {
            _ = try await GuideFileReader.shared.readGuide(at: root)
            XCTFail("Two guides must require an explicit choice")
        } catch GuideFileReader.ReadError.severalGuides {}
    }
}
