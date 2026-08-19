import XCTest
import RTICore

/// Characterizes the pure DiscussionGuide state machine (apply / unanswered /
/// coverage) and the match-response wire shape. Locks in the behavior the
/// periodic matcher relies on so the controller can be refactored over it.
final class DiscussionGuideTests: XCTestCase {

    private func quote(_ text: String, speaker: String? = "them_1", ms: Int? = 1000) -> GuideQuote {
        GuideQuote(text: text, speaker: speaker, timestampMs: ms)
    }

    /// Two-question guide, both pending.
    private func makeGuide() -> DiscussionGuide {
        DiscussionGuide(
            id: "g1",
            fileName: "guide.md",
            parsedAt: Date(timeIntervalSince1970: 0),
            objectives: [
                GuideObjective(
                    id: "obj_1",
                    title: "Objective",
                    description: nil,
                    sections: [
                        GuideSection(
                            id: "sec_1",
                            title: "Section",
                            questions: [
                                GuideQuestion(id: "q1", text: "First?", status: .pending, response: nil),
                                GuideQuestion(id: "q2", text: "Second?", status: .pending, response: nil)
                            ]
                        )
                    ],
                    takeaway: nil
                )
            ]
        )
    }

    func test_freshGuide_allQuestionsUnanswered() {
        let guide = makeGuide()
        XCTAssertEqual(guide.unansweredQuestions().map(\.id), ["q1", "q2"])
        let c = guide.coverage
        XCTAssertEqual(c.total, 2)
        XCTAssertEqual(c.answered, 0)
        XCTAssertEqual(c.percent, 0)
    }

    func test_applyPartialMatch_setsResponseButStaysUnanswered() {
        var guide = makeGuide()
        guide.apply(matches: [
            GuideMatch(questionId: "q1", summary: "partial take",
                       quotes: [quote("first quote")], confidence: .medium, status: .partial)
        ])

        let q1 = guide.objectives[0].sections[0].questions[0]
        XCTAssertEqual(q1.status, .partial)
        XCTAssertEqual(q1.response?.summary, "partial take")
        XCTAssertEqual(q1.response?.quotes.map(\.text), ["first quote"])
        // Partial is still "unanswered" for the matcher's purposes.
        XCTAssertEqual(guide.unansweredQuestions().map(\.id), ["q1", "q2"])
        XCTAssertEqual(guide.coverage.answered, 0)
    }

    func test_applyAnsweredMatch_removesFromUnansweredAndCounts() {
        var guide = makeGuide()
        guide.apply(matches: [
            GuideMatch(questionId: "q1", summary: "done",
                       quotes: [quote("q1 quote")], confidence: .high, status: .answered)
        ])

        XCTAssertEqual(guide.unansweredQuestions().map(\.id), ["q2"])
        XCTAssertEqual(guide.coverage.answered, 1)
        XCTAssertEqual(guide.coverage.percent, 50)
    }

    func test_applyTwice_dedupesQuotesByTextAndAppendsNovel() {
        var guide = makeGuide()
        guide.apply(matches: [
            GuideMatch(questionId: "q1", summary: "v1",
                       quotes: [quote("same quote")], confidence: .low, status: .partial)
        ])
        // Second pass repeats the same quote text and adds a new one.
        guide.apply(matches: [
            GuideMatch(questionId: "q1", summary: "v2",
                       quotes: [quote("same quote"), quote("new quote")], confidence: .high, status: .answered)
        ])

        let q1 = guide.objectives[0].sections[0].questions[0]
        XCTAssertEqual(q1.status, .answered)
        XCTAssertEqual(q1.response?.summary, "v2")
        XCTAssertEqual(q1.response?.quotes.map(\.text), ["same quote", "new quote"])
    }

    func test_applyUnknownQuestionId_isIgnored() {
        var guide = makeGuide()
        guide.apply(matches: [
            GuideMatch(questionId: "does_not_exist", summary: "x",
                       quotes: [quote("orphan")], confidence: .high, status: .answered)
        ])
        XCTAssertEqual(guide.unansweredQuestions().map(\.id), ["q1", "q2"])
        XCTAssertEqual(guide.coverage.answered, 0)
    }

    /// The matcher decodes the LLM's JSON into `{ "matches": [GuideMatch] }`.
    /// Lock in that the model's Codable conformances handle the documented
    /// wire shape (this is what the refactored controller decodes via
    /// `TranscriptAnalysis.run`).
    func test_matchResponse_decodesDocumentedWireShape() throws {
        struct Resp: Decodable { let matches: [GuideMatch] }
        let json = """
        {
          "matches": [
            {
              "questionId": "obj_1_sec_1_q1",
              "summary": "Participant described their workflow.",
              "quotes": [
                { "text": "I start with a quick scan.", "speaker": "them_1", "timestampMs": 123456 }
              ],
              "confidence": "high",
              "status": "answered"
            }
          ]
        }
        """
        let resp = try JSONExtractor.decode(json, as: Resp.self)
        XCTAssertEqual(resp.matches.count, 1)
        let m = resp.matches[0]
        XCTAssertEqual(m.questionId, "obj_1_sec_1_q1")
        XCTAssertEqual(m.confidence, .high)
        XCTAssertEqual(m.status, .answered)
        XCTAssertEqual(m.quotes.first?.timestampMs, 123456)
        XCTAssertEqual(m.quotes.first?.speaker, "them_1")
    }

    func testAssistantContextSummaryRendersStatusAndCoverage() {
        var guide = makeGuide()
        guide.apply(matches: [
            GuideMatch(questionId: "q1", summary: "Buys on price.",
                       quotes: [quote("It's the price.")], confidence: .high, status: .answered),
        ])
        let text = guide.assistantContextSummary()
        // Coverage header reflects 1 of 2 answered.
        XCTAssertTrue(text.contains("1/2 covered"))
        // Answered question is marked and carries its live summary; the other stays pending.
        XCTAssertTrue(text.contains("[x] First?"))
        XCTAssertTrue(text.contains("so far: Buys on price."))
        XCTAssertTrue(text.contains("[ ] Second?"))
    }
}
