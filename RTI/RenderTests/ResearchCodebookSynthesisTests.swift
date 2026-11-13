import Foundation
import RTICore
import XCTest

/// The ten-minute synthesis pass as the controller runs it (1.5): the clock
/// and new-quote gates, the two-minute retry after a failure, the sealed
/// guard, and the resets a new call makes. Every reply comes from a local
/// script; all text is invented (an oat drink).
@MainActor
final class ResearchCodebookSynthesisTests: RenderProofTestCase {
    /// Replies in order, and how many requests were sent.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var count = 0
        /// Runs before a reply is returned, to land a call change mid-request.
        var beforeReply: (@Sendable () async -> Void)?

        init(_ replies: [String]) {
            self.replies = replies
        }

        var sent: Int {
            lock.withLock { count }
        }

        func next() -> String {
            lock.withLock {
                count += 1
                return replies.isEmpty ? Self.empty : replies.removeFirst()
            }
        }

        static let empty = #"{"merges":[],"tensions":[],"hypotheses":[],"clientQuestions":[]}"#
        static let tension = #"{"merges":[],"tensions":[{"name_zh":"要快还是享受","turnID":"t5","counterTurnID":"t1"}],"hypotheses":[],"clientQuestions":[]}"#
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rti-synthesis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private func quote(_ id: String, _ minute: Double, _ original: String) -> ResearchQuote {
        ResearchQuote(sessionID: "s1", turnID: id, group: "G1", offsetMs: Int(minute * 60000), original: original,
                      speaker: .init(rawSpeaker: "remote", label: "Them", leg: "Them", confidence: "legOnly", seat: nil, segment: nil, moderator: false),
                      questionID: nil, revealRecorded: false)
    }

    private var sources: [ResearchQuote] {
        [quote("t1", 1, "早上要快。"), quote("t2", 2, "快最重要。"), quote("t3", 3, "燕麦奶太甜。"), quote("t4", 4, "甜得发腻。"),
         quote("t5", 25, "我喜欢慢慢喝，享受一下。"), quote("t6", 26, "慢慢喝才舒服。"), quote("t7", 27, "盒子打不开。"), quote("t8", 28, "盖子太紧。")]
    }

    /// Four codes, two quotes each, written where the store reads them.
    private func controller(_ script: Script) throws -> ResearchCodebookController {
        var book = ResearchCodebook()
        let session = ResearchCodebook.Session(id: "s1", group: "G1", startedAt: start, folder: folder.lastPathComponent)
        book.sessions = [session]
        book.apply(.init(entries: [
            .init(nameZh: "要快", type: .theme, turnID: "t1", point: "Speed."), .init(nameZh: "要快", type: .theme, turnID: "t2", point: "Speed."),
            .init(nameZh: "太甜", type: .theme, turnID: "t3", point: "Sweet."), .init(nameZh: "太甜", type: .theme, turnID: "t4", point: "Sweet."),
            .init(nameZh: "慢慢喝", type: .theme, turnID: "t5", point: "Slow."), .init(nameZh: "慢慢喝", type: .theme, turnID: "t6", point: "Slow."),
        ], names: nil), sources: sources)
        book.apply(.init(entries: [.init(nameZh: "难打开", type: .barrier, turnID: "t7", point: "Hard to open."),
                                   .init(nameZh: "难打开", type: .barrier, turnID: "t8", point: "Hard to open.")], names: nil), sources: sources)
        XCTAssertEqual(book.codeCount(in: "s1"), 4)
        try JSONEncoder().encode(book).write(to: folder.appendingPathComponent("codebook.json"))
        let controller = ResearchCodebookController(makeRequest: {
            LLMRequest(collectStream: { _, _, _, _ in
                await script.beforeReply?()
                return LLMClient.CollectedResponse(text: script.next(), finishReason: "stop", reasoningCharacters: 0)
            }, priority: .background, admission: LLMAdmissionController())
        })
        controller.attachForTest(book, at: .init(session: session, directory: folder, project: nil))
        return controller
    }

    func testSynthesisRunsAtTenMinutesAppliesTheReplyAndWaitsForNewQuotes() async throws {
        let script = Script([Script.tension])
        let codebook = try controller(script)
        await codebook.synthesize(sessionID: "s1", nowMs: 540_000)
        XCTAssertEqual(script.sent, 0, "not before ten minutes")
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(script.sent, 1)
        XCTAssertEqual(codebook.lastSynthesisMs, 600_000)
        XCTAssertEqual(codebook.quotesAtLastSynthesis, 10, "the tension's two re-cited quotes count as already seen")
        XCTAssertEqual(codebook.book.cards.filter { $0.type == .tension }.map(\.name), ["要快还是享受"], "the reply is applied")
        XCTAssertFalse(codebook.synthesizing)
        XCTAssertNil(codebook.error)
        await codebook.synthesize(sessionID: "s1", nowMs: 1_300_000)
        XCTAssertEqual(script.sent, 1, "ten more minutes but no new quote")
        await codebook.synthesize(sessionID: "s2", nowMs: 1_300_000)
        XCTAssertEqual(script.sent, 1, "never for another session")
    }

    func testAFailedSynthesisIsTriedAgainTwoMinutesLaterWithoutANewQuote() async throws {
        let script = Script(["not json", Script.empty])
        let codebook = try controller(script)
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(script.sent, 1)
        XCTAssertNotNil(codebook.error)
        XCTAssertEqual(codebook.quotesAtLastSynthesis, 0, "the failed pass does not use up the new quotes")
        await codebook.synthesize(sessionID: "s1", nowMs: 660_000)
        XCTAssertEqual(script.sent, 1, "not at once")
        await codebook.synthesize(sessionID: "s1", nowMs: 720_000)
        XCTAssertEqual(script.sent, 2, "two minutes later")
        XCTAssertNil(codebook.error)
        XCTAssertEqual(codebook.lastSynthesisMs, 720_000)
    }

    func testNoSynthesisAfterTheCallIsSealed() async throws {
        let script = Script([Script.tension])
        let codebook = try controller(script)
        await codebook.finish(sessionID: "s1", entries: [])
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(script.sent, 0)
        XCTAssertFalse(codebook.book.cards.contains { $0.type == .tension })
    }

    func testAReplyThatLandsAfterTheCallEndsIsDropped() async throws {
        let script = Script([Script.tension])
        let codebook = try controller(script)
        script.beforeReply = { await codebook.finish(sessionID: "s1", entries: []) }
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(script.sent, 1)
        XCTAssertFalse(codebook.book.cards.contains { $0.type == .tension }, "a sealed call takes no late synthesis")
        XCTAssertFalse(codebook.synthesizing)
    }

    func testANewCallResetsTheSynthesisClockAndDropsALateReply() async throws {
        let script = Script([Script.tension, Script.tension])
        let codebook = try controller(script)
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(codebook.lastSynthesisMs, 600_000)
        let begin = start
        script.beforeReply = { await codebook.start(sessionID: "s2", at: begin, callType: .internal) }
        let place = try XCTUnwrap(codebook.location)
        var book = codebook.book
        book.apply(.init(entries: [.init(nameZh: "要快", type: .theme, turnID: "t9", point: "Speed.")], names: nil),
                   sources: [quote("t9", 30, "还是快一点好。")])
        codebook.attachForTest(book, at: place)
        XCTAssertNil(codebook.lastSynthesisMs, "start clears the clock")
        XCTAssertEqual(codebook.quotesAtLastSynthesis, 0)
        await codebook.synthesize(sessionID: "s1", nowMs: 600_000)
        XCTAssertEqual(script.sent, 2)
        XCTAssertNil(codebook.location, "the new call is not a research call")
        XCTAssertFalse(codebook.synthesizing, "the new call starts idle")
        XCTAssertTrue(codebook.book.cards.isEmpty, "the old call's late reply never lands in the new call")
        XCTAssertNil(codebook.lastSynthesisMs)
    }
}
