import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// RTI Lite (2026-11-14): the ready page before a call, the live research
/// page at three widths, and an answer risen above the ask bar. Light and
/// dark. Invented fixture. PNG prefix `lite-`.
@MainActor
final class LiteRenderProofTests: RenderProofTestCase {
    private var guideSessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
        UserDefaults.standard.set(true, forKey: RTILiteSettings.enabledKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: RTILiteSettings.enabledKey)
        AutoAssistController.shared.clear()
        if let id = guideSessionID { GuideSessionController.shared.endSession(id) }
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        LLMController.shared.seedForRenderProof(entries: [])
        try await super.tearDown()
    }

    private func seedResearchCall() throws {
        let start = Date().addingTimeInterval(-4260)
        SessionCoordinator.shared.seedForRenderProof(entries: [
            RenderFixtures.liveEntry("self", "我们先聊聊杯子。你平时怎么带它出门？", 4_010_000),
            RenderFixtures.liveEntry("remote", "我一般放在包的侧袋里，这样拿起来方便。", 4_018_000),
            RenderFixtures.liveEntry("remote", "但是洗起来很麻烦，盖子那里总是有味道。", 4_031_000),
            RenderFixtures.liveEntry("self", "OK. And how would you clean the cup?", 4_055_000),
            RenderFixtures.liveEntry("remote", "Mostly by hand. The dishwasher scratches it, I think.", 4_062_000),
            RenderFixtures.liveEntry("remote", "洗起来很麻烦，所以有时候就不带了。", 4_079_000),
        ], interim: "我觉得如果盖子可以拆开", phase: .recording, startedAt: start, streamHealth: .live, systemHealth: .live)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        let id = "lite-guide"
        guideSessionID = id
        GuideSessionController.shared.start(sessionID: id, guide: guide, guideURL: url, group: "G1", roster: [],
                                            rosterURL: nil, startedAt: start)
        GuideSessionController.shared.select("S2Q1", at: start.addingTimeInterval(600))
        AutoAssistController.shared.seedRailForRenderProof([
            (LiveRailRenderProofTests.researchAsk, Date().addingTimeInterval(-2)),
        ], callType: .research)
    }

    private func livePage(answerOpen: Bool = false) -> some View {
        OverlayPanelView(statusOverride: OverlayShellStatus(phase: .recording, processingStatus: nil),
                         callTypes: CallTypeStore.inMemory(.research), liteAnswerStartsOpen: answerOpen)
            .environment(\.isWorkspaceEmbedded, true)
    }

    func testReadyPageBeforeACall() throws {
        let model = WorkspaceModel()
        try renderBothAppearances(name: "lite-ready-1080", size: WorkspaceLayout.standardSize,
                                  view: WorkspaceView(model: model, callTypes: .inMemory(.research)))
    }

    func testLiveResearchPageAtThreeWidths() throws {
        try seedResearchCall()
        for (label, size) in [("1440", CGSize(width: 1440, height: 900)), ("1080", CGSize(width: 1080, height: 720)),
                              ("720", CGSize(width: 720, height: 620))] {
            try renderBothAppearances(name: "lite-live-\(label)", size: size, view: livePage())
        }
    }

    func testAnswerRisesAboveTheAskBar() throws {
        try seedResearchCall()
        LLMController.shared.seedForRenderProof(entries: [
            ChatEntry(role: "user", text: "What are the themes so far?", action: "Ask", contextUsed: true, screenContextUsed: false),
            ChatEntry(role: "assistant", text: """
            - **Carry beats capacity:** the side pocket decides whether the cup leaves the house.
            - **Cleaning is the barrier:** 洗起来麻烦 comes up three times, always about the lid.
            - **Dishwasher doubt:** two people hand-wash because they think it scratches.
            """, action: "Ask", contextUsed: true, screenContextUsed: false),
        ])
        try renderBothAppearances(name: "lite-answer-1080", size: CGSize(width: 1080, height: 720),
                                  view: livePage(answerOpen: true))
    }

    func testLiteSkipsLiveNotesAndCodebookOnly() {
        let defaults = UserDefaults.standard
        XCTAssertTrue(RTILiteSettings.isOn(in: defaults))
        XCTAssertFalse(RTILiteSettings.runs(task: "notes", in: defaults))
        XCTAssertFalse(RTILiteSettings.runs(task: "researchCodebook", in: defaults))
        XCTAssertTrue(RTILiteSettings.runs(task: "guide", in: defaults))
        XCTAssertTrue(RTILiteSettings.runs(task: "auto", in: defaults))
        defaults.set(false, forKey: RTILiteSettings.enabledKey)
        XCTAssertTrue(RTILiteSettings.runs(task: "notes", in: defaults))
    }
}
