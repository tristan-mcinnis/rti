import Foundation
import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// The live help rail beside the transcript: a client rail and a research
/// rail, alone and in the Live page at 860 pt (rail) and 720 pt (strip),
/// plus the empty states. Light and dark. Invented fixtures only. PNG prefix
/// `live-rail-`.
final class LiveRailRenderProofTests: RenderProofTestCase {
    private static let railSize = CGSize(width: LiveRailLayout.width, height: 640)
    private static let wide = CGSize(width: 860, height: 620)
    private static let narrow = CGSize(width: 720, height: 620)

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: AutoAssistSettings.enabledKey)
    }

    override func tearDown() async throws {
        AutoAssistController.shared.clear()
        ResearchCodebookController.shared.seedForRenderProof(ResearchCodebook())
        if let id = guideSessionID {
            GuideSessionController.shared.endSession(id)
        }
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    private var guideSessionID: String?

    // MARK: - Fixtures

    private static func card(_ kind: AutoCardKind, _ text: String, zh: String? = nil, why: String = "") -> AutoAssistCard {
        AutoAssistCard(timestamp: Date(), kind: kind, text: text, textZH: zh, why: why, citation: nil)
    }

    private static func railCard(_ card: AutoAssistCard, pinned: Bool = false, age: TimeInterval,
                                 pinyin: Bool = true) -> LiveRailContent.Card
    {
        LiveRailContent.Card(id: card.id, kind: card.kind, text: card.text, why: card.why, source: card.source,
                             pinned: pinned, shownAt: Date().addingTimeInterval(-age), textZH: card.textZH,
                             pinyin: pinyin ? card.pinyin : nil)
    }

    static let clientNow = [
        card(.ask, "Who signs off on the pilot budget, and by when?", why: "Budget came up twice with no owner."),
        card(.say, "Offer a two-week pilot with one regional team before the full rollout.",
             why: "They worry about switching cost."),
        card(.recall, "Last quarter's pilot ran four weeks and paused for the holiday."),
    ]
    static let clientThread = card(.flag, "No owner yet for the vendor shortlist.")
    static let clientEarlier = card(.say, "Thank them for sending the usage numbers ahead of the call.")

    static let researchAsk = card(
        .ask,
        "Ask how they clean the lid seal.",
        zh: "大家平时怎么清洗杯盖的密封圈？",
        why: "Cleaning was mentioned, never probed."
    )
    static let researchAsk2 = card(
        .ask,
        "Ask who sees carrying it differently.",
        zh: "有没有人对带杯子出门有不一样的看法？"
    )
    /// A contradiction FLAG: two quotes with their times, the one FLAG a
    /// research pass may add beside its card.
    static let researchFlag = card(
        .flag,
        "10:18 “放在包的侧袋里” vs 11:19 “有时候就不带了”.",
        why: "Two quotes disagree on carrying the cup."
    )

    static var gaps: [GuideGap] {
        [
            GuideGap(qid: "S1Q2", title: "How would you carry the cup?", titleZH: "你会怎么带这个杯子？", state: .thin(quotes: 1)),
            GuideGap(qid: "S1Q1", title: "Which cup would you choose, A or B?", titleZH: "你会选哪个杯子，A 还是 B？", state: .skipped),
        ]
    }

    static var codebook: ResearchCodebook {
        func quote(_ id: String, _ offset: Int, _ original: String) -> ResearchQuote {
            let speaker = ResearchQuote.Attribution(rawSpeaker: "remote", label: "Them", leg: "Them", confidence: "legOnly",
                                                    seat: nil, segment: nil, moderator: false)
            return ResearchQuote(sessionID: "rail-fixture", turnID: id, group: "G1", offsetMs: offset, original: original,
                                 speaker: speaker, revealRecorded: false)
        }
        func entry(_ id: String, _ offset: Int, _ valence: ResearchValence, stance: ResearchStance? = nil) -> ResearchEntry {
            ResearchEntry(point: "A point.", evidence: quote(id, offset, "我每天都放在侧袋里。"), valence: valence, inferredName: nil, stance: stance)
        }
        func card(_ name: String, _ type: ResearchCardType, gloss: String? = nil, _ valences: [ResearchValence]) -> ResearchCard {
            ResearchCard(id: UUID(), name: name, aliases: [], type: type, origin: .emerged, pinned: false,
                         entries: valences.enumerated().map { entry("\(name)-\($0.offset)", 1000 * ($0.offset + 1), $0.element) },
                         gloss: gloss)
        }
        var carry = card("Carry beats capacity", .hypothesis, [])
        carry.entries = [entry("h1", 61000, .positive, stance: .support), entry("h2", 62000, .positive, stance: .support),
                         entry("h3", 63000, .negative, stance: .against)]
        var cleaning = card("洗不干净就不回购", .hypothesis, gloss: "Cleaning decides repurchase", [])
        cleaning.entries = [entry("h4", 64000, .negative, stance: .support)]
        var tension = card("说方便却不带", .tension, gloss: "Says it is handy, leaves it at home", [])
        tension.entries = [ResearchEntry(point: "Handy in words, left at home in practice.",
                                         evidence: quote("x2", 2_040_000, "其实我很少带出门，太重了。"), valence: .mixed, inferredName: nil,
                                         excerpt: "很少带出门，太重了", counter: quote("x1", 485_000, "这个杯子很方便，我天天带。"))]
        var vote = card("选A还是选B", .vote, gloss: "Cup A or cup B", [])
        vote.votes = [ResearchVote(sessionID: "rail-fixture", choice: "B", count: 5, source: "moderator_tally", turnID: "v1", offsetMs: 1_500_000),
                      ResearchVote(sessionID: "rail-fixture", choice: "A", count: 1, source: "moderator_tally", turnID: "v1", offsetMs: 1_500_000)]
        var question = card("Would they pay more for a leak-proof lid?", .clientQuestion, [.neutral])
        question.questionStatus = .partly
        var book = ResearchCodebook()
        book.cards = [
            card("Morning Cup（晨杯）", .brand, [.positive, .positive, .positive, .neutral]),
            card("Trail Flask", .brand, [.negative, .neutral]),
            card("便利店", .channel, gloss: "Corner shop", [.neutral]),
            card("小禾", .person, [.neutral, .neutral]),
            card("侧袋", .theme, gloss: "Side pocket", [.positive, .positive]),
            card("洗起来麻烦", .barrier, gloss: "Hard to clean", [.negative, .negative, .negative]),
            card("Dishwasher safe", .concept, [.positive, .negative]),
            card("Weight", .theme, [.neutral]),
            card("怕漏", .barrier, gloss: "Leak worry", [.negative]),
            card("送人", .theme, gloss: "Cup as a gift", [.positive]),
            carry, cleaning, tension, vote, question,
        ]
        book.cards += ["Straw lid", "Colour", "Price", "Gift box", "Shop shelf", "Kettle", "Desk", "Car holder", "Bag strap"]
            .map { card($0, .theme, [.neutral]) }
        return book
    }

    static var clientContent: LiveRailContent {
        var content = LiveRailContent(kind: .client)
        content.isRecording = true
        content.now = [
            railCard(clientNow[0], age: 1),
            railCard(clientNow[1], pinned: true, age: 62),
            railCard(clientNow[2], age: 123),
        ]
        content.threads = [railCard(clientThread, age: 184)]
        content.earlier = [railCard(clientEarlier, age: 300)]
        return content
    }

    static var researchContent: LiveRailContent {
        var content = LiveRailContent(kind: .research)
        content.isRecording = true
        content.guideActive = true
        content.question = .init(qid: "S2Q1", en: "How would you clean the cup?", zh: "你会怎么洗这个杯子？")
        content.gaps = gaps
        content.now = [railCard(researchAsk, age: 2), railCard(researchAsk2, age: 70)]
        content.threads = [railCard(researchFlag, age: 140)]
        content.topics = codebook.topicMap()
        return content
    }

    private func renderRail(_ name: String, _ content: LiveRailContent, height: CGFloat = railSize.height) throws {
        try renderBothAppearances(name: name, size: CGSize(width: Self.railSize.width, height: height),
                                  view: LiveAssistRail(content: content, actions: LiveRailActions(suggestNow: content.kind == .client ? {} : nil)))
    }

    // MARK: - The rail alone

    func testClientRail() throws {
        try renderRail("live-rail-client", Self.clientContent, height: 560)
    }

    func testResearchRail() throws {
        try renderRail("live-rail-research", Self.researchContent, height: 1320)
    }

    /// Mandarin first, pinyin under it, the English line as a small gloss;
    /// and the same card with the pinyin setting off.
    func testMandarinCardsWithAndWithoutPinyin() throws {
        var content = LiveRailContent(kind: .research)
        content.isRecording = true
        content.now = [Self.railCard(Self.researchAsk, age: 2)]
        content.threads = [Self.railCard(Self.researchFlag, age: 140)]
        try renderRail("live-rail-mandarin-pinyin", content, height: 360)
        content.now = [Self.railCard(Self.researchAsk, age: 2, pinyin: false)]
        try renderRail("live-rail-mandarin-no-pinyin", content, height: 360)
        XCTAssertEqual(content.now.first?.speakable, "大家平时怎么清洗杯盖的密封圈？", "Copy takes the line to say")
        XCTAssertTrue(AutoAssistSettings.showsPinyin(stored: nil), "pinyin is on until the user turns it off")
        XCTAssertFalse(AutoAssistSettings.showsPinyin(stored: false))
    }

    func testEmptyStates() throws {
        var client = LiveRailContent(kind: .client)
        client.isRecording = true
        try renderRail("live-rail-empty-client", client, height: 260)

        var research = LiveRailContent(kind: .research)
        research.guideActive = true
        research.topics = ResearchTopicMap()
        try renderRail("live-rail-empty-research", research, height: 380)

        var off = LiveRailContent(kind: .research)
        off.autoOn = false
        off.guideActive = true
        off.isRecording = true
        off.question = .init(qid: "S1Q1", en: "Which cup would you choose, A or B?", zh: "你会选哪个杯子，A 还是 B？")
        off.topics = ResearchTopicMap()
        try renderRail("live-rail-auto-off", off, height: 380)
    }

    func testStripAlone() throws {
        try renderBothAppearances(
            name: "live-rail-strip", size: CGSize(width: 680, height: 60),
            view: LiveRailStrip(summary: Self.researchContent.summary, open: {})
                .padding(House.Spacing.md).background(House.ColorToken.surface)
        )
    }

    // MARK: - In the Live page

    /// The shared meeting as the shipped default shows it: live diarization
    /// is off, so every system-leg row is plain "Them" (`remote`).
    static var undiarizedMeeting: [LiveEntry] {
        TranscriptRenderProofTests.meeting.map { row in
            let speaker = row.speakerId.hasPrefix("remote") ? "remote" : row.speakerId
            return RenderFixtures.liveEntry(speaker, row.text, row.startMs)
        }
    }

    private func seedClientCall() {
        let start = Date().addingTimeInterval(-780)
        SessionCoordinator.shared.seedForRenderProof(entries: Self.undiarizedMeeting, interim: nil, phase: .recording,
                                                     startedAt: start, streamHealth: .live, systemHealth: .live)
        let now = Date()
        AutoAssistController.shared.seedRailForRenderProof([
            (Self.clientEarlier, now.addingTimeInterval(-245)),
            (Self.clientThread, now.addingTimeInterval(-184)),
            (Self.clientNow[2], now.addingTimeInterval(-123)),
            (Self.clientNow[1], now.addingTimeInterval(-62)),
            (Self.clientNow[0], now.addingTimeInterval(-1)),
        ], callType: .client)
    }

    private func seedResearchCall() throws {
        let start = Date().addingTimeInterval(-900)
        SessionCoordinator.shared.seedForRenderProof(entries: [
            RenderFixtures.liveEntry("self", "我们先聊聊杯子。你平时怎么带它出门？", 610_000),
            RenderFixtures.liveEntry("remote", "我一般放在包的侧袋里，这样拿起来方便。", 618_000),
            RenderFixtures.liveEntry("remote", "但是洗起来很麻烦，盖子那里总是有味道。", 631_000),
            RenderFixtures.liveEntry("self", "OK. And how would you clean the cup?", 655_000),
            RenderFixtures.liveEntry("remote", "Mostly by hand. The dishwasher scratches it, I think.", 662_000),
            RenderFixtures.liveEntry("remote", "洗起来很麻烦，所以有时候就不带了。", 679_000),
        ], interim: nil, phase: .recording, startedAt: start, streamHealth: .live, systemHealth: .live)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        let id = "live-rail-guide"
        guideSessionID = id
        let controller = GuideSessionController.shared
        controller.start(sessionID: id, guide: guide, guideURL: url, group: "G1", roster: [], rosterURL: nil, startedAt: start)
        controller.select("S2Q1", at: start.addingTimeInterval(600))
        XCTAssertEqual(controller.gaps.map(\.qid), ["S1Q2", "S1Q1"])
        ResearchCodebookController.shared.seedForRenderProof(Self.codebook)
        let now = Date()
        AutoAssistController.shared.seedRailForRenderProof([
            (Self.researchFlag, now.addingTimeInterval(-140)),
            (Self.researchAsk2, now.addingTimeInterval(-70)),
            (Self.researchAsk, now.addingTimeInterval(-2)),
        ], callType: .research)
    }

    private func renderLivePage(_ name: String, size: CGSize, callType: CallType) throws {
        try renderBothAppearances(
            name: name, size: size,
            view: OverlayPanelView(statusOverride: OverlayShellStatus(phase: .recording, processingStatus: nil),
                                   callTypes: CallTypeStore.inMemory(callType))
                .onAppear { NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue) }
        )
    }

    func testClientLivePageWideAndNarrow() throws {
        seedClientCall()
        try renderLivePage("live-rail-page-client-860", size: Self.wide, callType: .client)
        try renderLivePage("live-rail-page-client-720", size: Self.narrow, callType: .client)
    }

    func testResearchLivePageWideAndNarrow() throws {
        try seedResearchCall()
        try renderLivePage("live-rail-page-research-860", size: Self.wide, callType: .research)
        try renderLivePage("live-rail-page-research-720", size: Self.narrow, callType: .research)
    }
}

/// The rail's rules without drawing: when it shows, what the strip says, and
/// what it reads from the live controllers.
@MainActor
final class LiveRailContentTests: RenderProofTestCase {
    override func tearDown() async throws {
        AutoAssistController.shared.clear()
        try await super.tearDown()
    }

    func testRailFoldsToTheStripBelowTheThreshold() {
        XCTAssertEqual(LiveRailLayout.mode(width: 860, applies: true), .rail)
        XCTAssertEqual(LiveRailLayout.mode(width: 720, applies: true), .strip)
        XCTAssertEqual(LiveRailLayout.mode(width: LiveRailLayout.stripBelow, applies: true), .rail)
        XCTAssertEqual(LiveRailLayout.mode(width: 1200, applies: false), .none)
        XCTAssertGreaterThanOrEqual(LiveRailLayout.width, 280)
        XCTAssertLessThanOrEqual(LiveRailLayout.width, 300)
    }

    func testStripSummarySaysQuotesAndCountsNotPeople() {
        let research = LiveRailRenderProofTests.researchContent
        XCTAssertEqual(research.summary, "2 to ask · 1 flag · 2 to revisit · 23 topics",
                       "a thin question was asked, so gaps are to revisit, not missed")
        XCTAssertEqual(LiveRailRenderProofTests.clientContent.summary, "3 suggestions · 1 open thread")
        XCTAssertEqual(LiveRailContent(kind: .client).summary, "No suggestions yet")
        XCTAssertEqual(LiveRailContent(kind: .research).summary, "Nothing to ask yet")
        var off = LiveRailContent(kind: .client)
        off.autoOn = false
        XCTAssertEqual(off.summary, "Auto is off for this call")
        var guideOnly = LiveRailContent(kind: .research)
        guideOnly.autoOn = false
        guideOnly.guideActive = true
        XCTAssertEqual(guideOnly.summary, "Auto is off for this call", "no cards will come, so do not promise any")
        XCTAssertEqual(LiveRailRenderProofTests.gaps.map(\.detail), ["Thin: 1 quote", "Skipped"])
    }

    func testLiveContentReadsThePacedRailAndHidesCardsWhenAutoIsOff() {
        let now = Date()
        let first = LiveRailRenderProofTests.clientNow[0], second = LiveRailRenderProofTests.clientNow[1]
        let flag = LiveRailRenderProofTests.clientThread
        let auto = AutoAssistController.shared
        auto.seedRailForRenderProof([(flag, now.addingTimeInterval(-130)), (second, now.addingTimeInterval(-65)),
                                     (first, now)], callType: .client)
        auto.pin(second.id)
        let content = LiveRailContent.live(callType: .client, autoOn: true, guide: GuideSessionController())
        XCTAssertEqual(content.kind, .client)
        XCTAssertEqual(content.now.map(\.id), [first.id, second.id], "newest first")
        XCTAssertEqual(content.now.map(\.pinned), [false, true])
        XCTAssertEqual(content.threads.map(\.id), [flag.id])
        XCTAssertNil(content.topics, "topics are for research calls")
        let off = LiveRailContent.live(callType: .client, autoOn: false, guide: GuideSessionController())
        XCTAssertTrue(off.now.isEmpty && off.threads.isEmpty)
        auto.dismiss(first.id)
        XCTAssertEqual(LiveRailContent.live(callType: .client, autoOn: true, guide: GuideSessionController()).now.map(\.id), [second.id])
    }

    func testAHeldLaneDropsADismissedCardAtOnceAndCountsArrivals() {
        let cards = LiveRailRenderProofTests.clientContent.now
        let held = Array(cards.prefix(2))
        XCTAssertEqual(LiveRailHold.shown(cards: cards, held: nil).map(\.id), cards.map(\.id))
        XCTAssertEqual(LiveRailHold.arrived(cards: cards, held: held), 1)
        let afterDismiss = cards.filter { $0.id != held[0].id }
        XCTAssertEqual(LiveRailHold.shown(cards: afterDismiss, held: held).map(\.id), [held[1].id],
                       "a dismissed card leaves even while the pointer holds the lane")
        var pinned = afterDismiss
        pinned[0].pinned = true
        XCTAssertEqual(LiveRailHold.shown(cards: pinned, held: held).map(\.pinned), [true], "held cards show their current state")
    }

    func testDismissThroughTheControllerLeavesTheLiveContent() {
        let now = Date()
        let first = LiveRailRenderProofTests.clientNow[0], second = LiveRailRenderProofTests.clientNow[1]
        let auto = AutoAssistController.shared
        auto.seedRailForRenderProof([(second, now.addingTimeInterval(-65)), (first, now)], callType: .client)
        let held = LiveRailContent.live(callType: .client, autoOn: true, guide: GuideSessionController()).now
        auto.dismiss(first.id)
        let after = LiveRailContent.live(callType: .client, autoOn: true, guide: GuideSessionController()).now
        XCTAssertEqual(LiveRailHold.shown(cards: after, held: held).map(\.id), [second.id])
    }

    func testRecordingStartLandsOnTheTranscriptWhenLiveHelpApplies() {
        typealias Row = (previous: SessionPhase, current: SessionPhase, selection: OverlayTab, auto: Bool, guide: Bool,
                         lands: OverlayTab?, name: String)
        let rows: [Row] = [
            (.idle, .recording, .setup, true, false, .transcript, "Auto on: a fresh start lands on the transcript"),
            (.idle, .recording, .setup, true, true, .transcript, "guide and Auto: transcript, not the Guide tab"),
            (.idle, .recording, .setup, false, true, .transcript, "a guide alone brings the rail: transcript, not Guide"),
            (.done, .recording, .setup, false, true, .transcript, "a guide start after a finished call, Auto off"),
            (.done, .recording, .setup, true, true, .transcript, "a guide start after a finished call"),
            (.done, .recording, .setup, true, false, nil, "no guide, not from idle: stay"),
            (.paused, .recording, .setup, true, true, nil, "resume never moves the user"),
            (.paused, .recording, .setup, false, true, nil, "resume with a guide stays"),
            (.idle, .recording, .setup, false, false, .assist, "no live help: Assist, as before"),
            (.idle, .recording, .notes, true, true, nil, "the user already left Prepare"),
            (.recording, .paused, .setup, true, true, nil, "only the move into recording lands"),
        ]
        for row in rows {
            XCTAssertEqual(LiveLanding.tab(previous: row.previous, current: row.current, selection: row.selection,
                                           autoOn: row.auto, guideActive: row.guide, callType: .research),
                           row.lands, row.name)
        }
        // The rail draws a guide only on research calls. Elsewhere a guided
        // start with Auto off has no rail and lands on the Guide tab.
        let nonResearch: [Row] = [
            (.idle, .recording, .setup, false, true, .guide, "a guide alone on a non-research call: Guide tab"),
            (.done, .recording, .setup, false, true, .guide, "a guide start after a finished call: Guide tab"),
            (.idle, .recording, .setup, true, true, .transcript, "Auto on still brings the rail"),
            (.idle, .recording, .setup, false, false, .assist, "no guide, no Auto: Assist"),
            (.paused, .recording, .setup, false, true, nil, "resume with a guide stays"),
        ]
        for callType in [CallType.client, .internal, .personal] {
            for row in nonResearch {
                XCTAssertEqual(LiveLanding.tab(previous: row.previous, current: row.current, selection: row.selection,
                                               autoOn: row.auto, guideActive: row.guide, callType: callType),
                               row.lands, "\(callType): \(row.name)")
            }
        }
    }

    func testTopicsShowOnlyWhileTheCallRecords() {
        ResearchCodebookController.shared.seedForRenderProof(LiveRailRenderProofTests.codebook)
        defer {
            ResearchCodebookController.shared.seedForRenderProof(ResearchCodebook())
            SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        }
        for phase in [SessionPhase.idle, .done] {
            SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: phase, startedAt: nil)
            let content = LiveRailContent.live(callType: .research, autoOn: true, guide: GuideSessionController())
            XCTAssertNil(content.topics, "\(phase): the browsed codebook is a past session's")
            XCTAssertFalse(content.summary.contains("topic"), "\(phase)")
        }
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: Date())
        let live = LiveRailContent.live(callType: .research, autoOn: true, guide: GuideSessionController())
        XCTAssertEqual(live.topics?.total, 23)
    }

    func testRailShowsWhatThePacerHoldsBack() {
        let now = Date()
        let auto = AutoAssistController.shared
        let cards = LiveRailRenderProofTests.clientNow
        auto.seedRailForRenderProof(cards.map { ($0, now) }, callType: .client)
        let content = LiveRailContent.live(callType: .client, autoOn: true, guide: GuideSessionController())
        XCTAssertEqual(content.now.count, 1)
        XCTAssertEqual(content.nowWaiting, 2)
        XCTAssertEqual(content.threadsWaiting, 0)
    }
}
