import Foundation
import RTICore
import XCTest

/// The guide pass loop (P2, P8): a failed pass is retried once at its own
/// size, empty passes back off, a moderator line reading a guide question
/// sets the position, and the payload sends full wording only near the
/// current section. Every reply comes from a local script; all text is invented.
@MainActor
final class GuidePassControllerTests: RenderProofTestCase {
    /// Replies in order, and every user message sent.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var sentMessages: [String] = []

        init(_ replies: [String]) {
            self.replies = replies
        }

        var sent: [String] {
            lock.withLock { sentMessages }
        }

        func next(_ messages: [LLMMessage]) -> String {
            lock.withLock {
                sentMessages.append(messages.last?.content ?? "")
                return replies.isEmpty ? Self.empty : replies.removeFirst()
            }
        }

        static let empty = #"{"suggestion":null,"evidence":[],"cells":[]}"#
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")

    private func controller(_ script: Script, guide: GuideDocument? = nil) throws -> GuideSessionController {
        let request = LLMRequest(collectStream: { messages, _, _, _ in
            LLMClient.CollectedResponse(text: script.next(messages), finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let controller = GuideSessionController(request: request)
        let document = try guide ?? GuideDocument.parse(Data(contentsOf: fixtureURL))
        controller.start(sessionID: "pass-fixture", guide: document, guideURL: fixtureURL, group: nil, roster: [],
                         rosterURL: nil, startedAt: start)
        return controller
    }

    private func newEvidenceCount(_ message: String) -> Int {
        message.components(separatedBy: #""newEvidence":true"#).count - 1
    }

    func testAFailedPassIsRetriedOnceAtItsOwnSizeThenGivenUp() async throws {
        let script = Script(["not json", "still not json", Script.empty])
        let guide = try controller(script)
        var entries = [RenderFixtures.liveEntry("remote_1", "I rinse it every night.", 1000),
                       RenderFixtures.liveEntry("remote_2", "I use the dishwasher.", 5000)]
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(30))
        XCTAssertNotNil(guide.lastError)

        entries.append(RenderFixtures.liveEntry("remote_3", "I never wash the lid.", 20000))
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(60))
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(90))
        XCTAssertEqual(script.sent.map(newEvidenceCount), [2, 2, 1], "the retry keeps its size; a newer turn waits")
        XCTAssertNil(guide.lastError)
        XCTAssertEqual(guide.snapshot(for: "pass-fixture")?.extraction.captureIncomplete, true,
                       "turns given up after two failures mark the capture incomplete")
    }

    func testEmptyPassesBackOffToEveryThirdTick() async throws {
        let script = Script([])
        let guide = try controller(script)
        var entries: [LiveEntry] = []
        for tick in 0 ..< 9 {
            entries.append(RenderFixtures.liveEntry("remote_\(tick + 1)", "Line \(tick).", 1000 + tick * 10000))
            await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(Double(30 + tick * 10)))
        }
        // Three empty passes, then ticks 4 and 5 skip, tick 6 runs, 7 and 8 skip, tick 9 runs.
        XCTAssertEqual(script.sent.count, 5)
        XCTAssertEqual(guide.emptyStreak, 5)
        entries.append(RenderFixtures.liveEntry("remote_10", "Line 9.", 100_000))
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(130), explicit: true)
        XCTAssertEqual(script.sent.count, 6, "the button skips the back-off")
    }

    func testAModeratorReadOnABackedOffTickMovesThePositionAndEndsTheBackOff() async throws {
        let script = Script([])
        let guide = try controller(script)
        var entries: [LiveEntry] = []
        for tick in 0 ..< 3 {
            entries.append(RenderFixtures.liveEntry("remote_\(tick + 1)", "Line \(tick).", 1000 + tick * 10000))
            await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(Double(30 + tick * 10)))
        }
        XCTAssertEqual(guide.emptyStreak, 3)
        entries.append(RenderFixtures.liveEntry("remote_4", "好，那下一个问题，你会怎么洗这个杯子？", 40000))
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(70))
        XCTAssertEqual(guide.currentQuestionID, "S2Q1", "a backed-off tick still reads the moderator line")
        XCTAssertEqual(script.sent.count, 4, "the move ends the back-off, so the pass runs")
        XCTAssertEqual(guide.emptyStreak, 0)
    }

    func testAModeratorLineReadingAnotherQuestionReleasesAManualPick() async throws {
        let guide = try controller(Script([]))
        guide.select("S1Q1", at: start.addingTimeInterval(10))
        XCTAssertFalse(guide.isFollowing)
        let entries = [RenderFixtures.liveEntry("remote_1", "好，那下一个问题，你会怎么洗这个杯子？", 40000),
                       RenderFixtures.liveEntry("remote_2", "我一般用热水冲一下。", 45000)]
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(60))
        XCTAssertTrue(guide.isFollowing, "the room moved on, so the pick is released")
        XCTAssertEqual(guide.currentQuestionID, "S2Q1")
        XCTAssertEqual(guide.questionID(atTranscriptMs: 20000), "S1Q1", "talk before the move stays with the pick")
    }

    func testAFreshManualPickHoldsAgainstAGuidePass() async throws {
        let early = try controller(Script([#"{"suggestion":"S2Q1","evidence":[],"cells":[]}"#]))
        early.select("S1Q1", at: start.addingTimeInterval(10))
        await early.generate(sessionId: "pass-fixture", entries: [RenderFixtures.liveEntry("remote_1", "Line one.", 20000),
                                                                  RenderFixtures.liveEntry("remote_2", "我一般用热水冲一下。", 30000)],
                             at: start.addingTimeInterval(40))
        XCTAssertEqual(early.currentQuestionID, "S1Q1", "a fresh pick holds against a pass")
    }

    func testAModeratorLineReadingAGuideQuestionSetsThePosition() async throws {
        let guide = try controller(Script([]))
        XCTAssertEqual(guide.currentQuestionID, "S1Q1")
        let entries = [RenderFixtures.liveEntry("remote_1", "好，那下一个问题，你会怎么洗这个杯子？", 4000),
                       RenderFixtures.liveEntry("remote_2", "我一般用热水冲一下。", 9000)]
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(30))
        XCTAssertEqual(guide.currentQuestionID, "S2Q1", "one moderator line establishes the question")
        XCTAssertEqual(guide.questionID(atTranscriptMs: 9000), "S2Q1")
        XCTAssertEqual(guide.autoQuestion(at: start.addingTimeInterval(60))?.qid, "S2Q1")
        XCTAssertNil(guide.autoQuestion(at: start.addingTimeInterval(400)), "a position over four minutes old is uncertain")
    }

    func testPayloadSendsFullWordingOnlyNearTheCurrentSectionAndRoleHints() async throws {
        func section(_ number: Int, _ minutes: Int) -> [String: Any] {
            ["id": "S\(number)", "title": "Part \(number)", "minutes": minutes, "questions": [
                ["qid": "S\(number)Q1", "en": "Invented question \(number) about oat drinks?", "zh": "关于燕麦饮品的虚构问题\(number)？", "probes": []],
            ]]
        }
        let json: [String: Any] = ["title": "Invented", "sections": [section(1, 5), section(2, 10), section(3, 10), section(4, 15)]]
        let document = try GuideDocument.parse(JSONSerialization.data(withJSONObject: json))
        let script = Script([])
        let guide = try controller(script, guide: document)
        let entries = [RenderFixtures.liveEntry("remote_1", "你平时早上喝什么？我一般喝燕麦奶。", 1000)]
        await guide.generate(sessionId: "pass-fixture", entries: entries, at: start.addingTimeInterval(30))
        let message = try XCTUnwrap(script.sent.first)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sections = try XCTUnwrap(input["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.map { $0["minutes"] as? Int }, [5, 10, 10, 15])
        let questions = sections.compactMap { ($0["questions"] as? [[String: Any]])?.first }
        XCTAssertEqual(questions.map { $0["en"] != nil }, [true, true, false, false], "S1 and S2 in full, S3 and S4 by title")
        XCTAssertEqual(questions[3]["title"] as? String, "Invented question 4 about oat drinks?")
        let turns = try XCTUnwrap(input["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["text"] as? String }, ["你平时早上喝什么？", "我一般喝燕麦奶。"], "the merged turn splits")
        XCTAssertEqual(turns.map { $0["role"] as? String }, ["moderator", "respondent"])
    }

    // MARK: Split pieces

    /// One system-leg utterance timed one character every 200 ms, as Soniox
    /// tokens with no pause, so it stays one utterance as it grows.
    private func utterance(_ text: String, from start: Int, speaker: String = "remote") -> [LiveEntry] {
        let tokens = text.enumerated().map { offset, character in
            LiveEntry.TimedToken(text: String(character), startMs: start + offset * 200, endMs: start + offset * 200 + 150)
        }
        return [LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1, translationStatus: "none",
                          language: "zh", sourceLanguage: nil, textOrigin: .providerTokens, streamID: UUID(), tokens: tokens)]
    }

    private func newEvidenceTexts(_ message: String) throws -> [String] {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let turns = try XCTUnwrap(input["turns"] as? [[String: Any]])
        return turns.filter { $0["newEvidence"] as? Bool == true }.compactMap { $0["text"] as? String }
    }

    func testASplitPieceKeepsItsIDWhileItsUtteranceGrowsAndIsSentOnce() async throws {
        let first = "你平时喝什么？我喝燕麦奶。那你呢？我也是。"
        let grown = first + "每天早上都喝一杯，因为方便。"
        let before = GuideTranscript.sources(from: utterance(first, from: 1000))
        let after = GuideTranscript.sources(from: utterance(grown, from: 1000))
        XCTAssertEqual(before.map(\.turn.id), ["remote@1000", "remote@1000#p1", "remote@1000#p2"])
        XCTAssertEqual(after.map(\.turn.id), before.map(\.turn.id), "the piece IDs do not move")
        XCTAssertNotEqual(before[1].turn.startMs, after[1].turn.startMs, "the interpolated time does move")

        // The first pass runs while the utterance is still open: only the two
        // finished pieces are ready. The second pass sends only the grown tail.
        let script = Script([])
        let guide = try controller(script)
        await guide.generate(sessionId: "pass-fixture", entries: utterance(first, from: 1000), at: start.addingTimeInterval(6.5))
        await guide.generate(sessionId: "pass-fixture", entries: utterance(grown, from: 1000), at: start.addingTimeInterval(20))
        XCTAssertEqual(script.sent.count, 2)
        XCTAssertEqual(try newEvidenceTexts(script.sent[0]), ["你平时喝什么？", "我喝燕麦奶。那你呢？"])
        XCTAssertEqual(try newEvidenceTexts(script.sent[1]), ["我也是。每天早上都喝一杯，因为方便。"], "no piece is sent twice")
    }

    func testASpokenTallySplitAtItsQuestionMarkBecomesOneVoteRecord() async throws {
        // An in-room group with labels off: the moderator's tally reaches the
        // system leg as one utterance, and the split cuts it at 选A的呢？.
        let json: [String: Any] = ["title": "Invented", "sections": [
            ["id": "S1", "title": "Choice", "minutes": 10, "questions": [
                ["qid": "S1Q1", "en": "Which drink would you pick, A or B?", "zh": "你们会选哪一款饮品，A还是B？", "probes": []],
            ]],
        ]]
        let document = try GuideDocument.parse(JSONSerialization.data(withJSONObject: json))
        let tally = "选B的举手，一二三四五，五位。选A的呢？一位。"
        let sources = GuideTranscript.sources(from: utterance(tally, from: 60000))
        XCTAssertEqual(sources.map(\.turn.text), ["选B的举手，一二三四五，五位。选A的呢？", "一位。"])
        XCTAssertEqual(sources.map(\.turn.id), ["remote@60000", "remote@60000#p1"])
        // The model cites the count piece for A, the first piece for B, and
        // puts a count on a respondent's pick, which is no tally.
        let reply = #"""
        {"suggestion":"S1Q1","evidence":[],"cells":[{"qid":"S1Q1","coverage":"Lightly covered","summary":"Most chose B.",
         "turns":["remote@50000","remote@60000","remote@60000#p1"],"quotes":[],
         "votes":[{"turn":"remote@60000","choice":"B","count":5,"source":"moderator_tally"},
                  {"turn":"remote@60000#p1","choice":"A","count":1,"source":"moderator_tally"},
                  {"turn":"remote@50000","choice":"B","count":3}]}]}
        """#
        let guide = try controller(Script([reply]), guide: document)
        let entries = RenderFixtures.liveEntry("remote", "我会选B，看起来更清爽。", 50000)
        await guide.generate(sessionId: "pass-fixture", entries: [entries] + utterance(tally, from: 60000),
                             at: start.addingTimeInterval(90))
        let cell = try XCTUnwrap(guide.snapshot(for: "pass-fixture")?.extraction.cells.first { $0.qid == "S1Q1" })
        XCTAssertEqual(cell.tally, "1 chose A; 5 chose B (show of hands)")
        XCTAssertTrue(cell.hasHandTally)
    }
}
