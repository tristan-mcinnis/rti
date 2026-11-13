import RTICore
import XCTest

final class GuideGapsTests: XCTestCase {
    private func guide(_ count: Int = 4) throws -> GuideDocument {
        let items: [[String: Any]] = (1 ... count).map { number in
            ["qid": "S1Q\(number)", "en": "Question \(number)?", "zh": "问题\(number)？", "probes": []]
        }
        let json: [String: Any] = ["title": "Invented guide", "sections": [["id": "S1", "title": "Section 1", "questions": items]]]
        return try GuideDocument.parse(JSONSerialization.data(withJSONObject: json))
    }

    /// S1Q1 ... S1Q`first`, then S2Q1 ... S2Q`second`: reaching S2 closes S1.
    private func twoSections(_ first: Int, _ second: Int) throws -> [GuideDocument.Question] {
        func items(_ section: Int, _ count: Int) -> [[String: Any]] {
            (1 ... count).map { ["qid": "S\(section)Q\($0)", "en": "Question \(section).\($0)?", "zh": "问题\(section).\($0)？", "probes": []] }
        }
        let json: [String: Any] = ["title": "Invented guide", "sections": [
            ["id": "S1", "title": "Section 1", "questions": items(1, first)],
            ["id": "S2", "title": "Section 2", "questions": items(2, second)],
        ]]
        return try GuideDocument.parse(JSONSerialization.data(withJSONObject: json)).questions
    }

    /// A stored cell as decoded from disk. Only the selection tests use it; evidence
    /// rules are tested through the real extraction path below.
    private func cell(_ qid: String, _ coverage: String = "Not covered", quotes: Int = 0) throws -> GuideCell {
        let quoteItems: [[String: Any]] = (0 ..< quotes).map { index in
            ["participant": "Them", "locator": "00:01", "original": "原话\(index)", "english": "Words \(index)",
             "raw_speaker": "remote", "live_start_ms": 1000 * index, "turn_id": "\(qid)-t\(index)"]
        }
        let json: [String: Any] = ["qid": qid, "coverage": coverage, "summary": "", "quotes": quoteItems, "who": "",
                                   "note_evidence": [], "vote_evidence": []]
        return try JSONDecoder().decode(GuideCell.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func gaps(_ cells: [GuideCell], furthest: Int, current: String?, count: Int = 4,
                      rosterSize: Int? = nil) throws -> [GuideGap]
    {
        try GuideGaps.find(questions: guide(count).questions, cells: cells, furthestIndex: furthest,
                           currentQID: current, rosterSize: rosterSize)
    }

    // MARK: Real extraction path

    private func turn(_ id: String, _ speaker: String, _ startMs: Int) -> GuideTurn {
        GuideTurn(id: id, speaker: speaker, startMs: startMs, text: "我会每天用这个杯子 \(id).")
    }

    private func pass(_ coverage: String, turns: [String], quotes: [String]? = nil,
                      summary: String = "A respondent described daily use.") throws -> GuidePass
    {
        let cell: [String: Any] = ["qid": "S1Q1", "coverage": coverage, "summary": summary, "turns": turns,
                                   "quotes": (quotes ?? turns).map { ["turn": $0, "english": "I would use this cup daily."] },
                                   "votes": []]
        let json: [String: Any] = ["suggestion": NSNull(), "evidence": [], "cells": [cell]]
        return try JSONDecoder().decode(GuidePass.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func extraction() throws -> GuideExtraction {
        try GuideExtraction(group: "G1", transcript: "transcript.live.md", guide: guide())
    }

    /// Gaps for S1Q1 once the moderator has moved on to S1Q2.
    private func firstQuestionGaps(_ extraction: GuideExtraction, rosterSize: Int? = nil) throws -> [GuideGap] {
        try GuideGaps.find(questions: guide().questions, cells: extraction.cells, furthestIndex: 1,
                           currentQID: "S1Q2", rosterSize: rosterSize)
    }

    func testLightlyCoveredQuestionResolvesWhenItBecomesAnswered() throws {
        var extraction = try extraction()
        try extraction.apply(pass("Lightly covered", turns: ["t1"]), turns: [turn("t1", "remote", 1000)],
                             speakers: [:], rosterBase: nil)
        XCTAssertEqual(extraction.cells.first?.coverage, "Lightly covered")
        let thin = try firstQuestionGaps(extraction)
        XCTAssertEqual(thin.map(\.state), [.thin(quotes: 1)])
        XCTAssertEqual(thin.first?.detail, "Thin: 1 quote")

        try extraction.apply(pass("Answered", turns: ["t2"], summary: "They use it on the commute."),
                             turns: [turn("t2", "remote", 5000)], speakers: [:], rosterBase: nil)
        XCTAssertEqual(extraction.cells.first?.coverage, "Answered")
        XCTAssertEqual(extraction.cells.first?.who, "")
        XCTAssertTrue(try firstQuestionGaps(extraction).isEmpty)
    }

    func testAnsweredWithOneUnseatedQuoteStaysThin() throws {
        var extraction = try extraction()
        try extraction.apply(pass("Answered", turns: ["t1"]), turns: [turn("t1", "remote", 1000)], speakers: [:], rosterBase: nil)
        XCTAssertEqual(extraction.cells.first?.coverage, "Answered")
        XCTAssertEqual(try firstQuestionGaps(extraction).map(\.state), [.thin(quotes: 1)])
    }

    func testNoteOnlyEvidenceSaysNoQuotesRatherThanZero() throws {
        var extraction = try extraction()
        try extraction.apply(pass("Answered", turns: ["t1"], quotes: []), turns: [turn("t1", "remote", 1000)],
                             speakers: [:], rosterBase: nil)
        XCTAssertEqual(extraction.cells.first?.coverage, "Lightly covered")
        let result = try firstQuestionGaps(extraction)
        XCTAssertEqual(result.map(\.state), [.thin(quotes: 0)])
        XCTAssertEqual(result.first?.detail, "Thin: mentioned, no quotes")
        XCTAssertFalse(result.first?.detail.contains("0") ?? true)
    }

    func testOneRespondentInterviewResolvesOnceItsSeatIsAssigned() throws {
        // An IDI with live labels on: the user assigns remote_1 to the one roster seat.
        var extraction = try extraction()
        try extraction.apply(pass("Answered", turns: ["t1", "t2"]),
                             turns: [turn("t1", "remote_1", 1000), turn("t2", "remote_1", 4000)], speakers: [:], rosterBase: 1)
        XCTAssertTrue(try firstQuestionGaps(extraction, rosterSize: 1).isEmpty)
        extraction.remap(speakers: ["remote_1": GuideSpeaker(participant: "P1", seatCode: "1U")], rosterBase: 1)
        XCTAssertEqual(extraction.cells.first?.who, "1U")
        XCTAssertTrue(try firstQuestionGaps(extraction, rosterSize: 1).isEmpty, "a seat must not turn an answered IDI thin")
    }

    func testMixedSeatedAndUnseatedQuotesCountQuotes() throws {
        // remote_1 is seated, remote_2 is not: who reads "1U" although two people answered.
        let speakers = ["remote_1": GuideSpeaker(participant: "P1", seatCode: "1U")]
        var extraction = try extraction()
        try extraction.apply(pass("Answered", turns: ["a", "b", "c", "d"]),
                             turns: [turn("a", "remote_1", 1000), turn("b", "remote_2", 2000),
                                     turn("c", "remote_2", 3000), turn("d", "remote_2", 4000)],
                             speakers: speakers, rosterBase: 6)
        XCTAssertEqual(extraction.cells.first?.who, "1U")
        XCTAssertTrue(try firstQuestionGaps(extraction, rosterSize: 6).isEmpty)
    }

    func testFullySeatedGroupNeedsTwoSeats() throws {
        let one = ["remote_1": GuideSpeaker(participant: "P1", seatCode: "1U")]
        var extraction = try extraction()
        try extraction.apply(pass("Answered", turns: ["a", "b", "c"]),
                             turns: [turn("a", "remote_1", 1000), turn("b", "remote_1", 2000), turn("c", "remote_1", 3000)],
                             speakers: one, rosterBase: 6)
        let flagged = try firstQuestionGaps(extraction, rosterSize: 6)
        XCTAssertEqual(flagged.map(\.state), [.oneSeat(quotes: 3)])
        XCTAssertEqual(flagged.first?.detail, "Thin: one seat, 3 quotes")

        try extraction.apply(pass("Answered", turns: ["e"], summary: "A second respondent agreed."),
                             turns: [turn("e", "remote_2", 6000)],
                             speakers: one.merging(["remote_2": GuideSpeaker(participant: "P2", seatCode: "2U")]) { $1 },
                             rosterBase: 6)
        XCTAssertEqual(extraction.cells.first?.who, "1U 2U")
        XCTAssertTrue(try firstQuestionGaps(extraction, rosterSize: 6).isEmpty)
    }

    func testModeratorQuotesNeverCountAsEvidence() throws {
        var extraction = try extraction()
        let speakers = ["remote_3": GuideSpeaker(participant: "Moderator", isModerator: true)]
        try extraction.apply(pass("Answered", turns: ["a", "b"]),
                             turns: [turn("a", "remote_3", 1000), turn("b", "remote_3", 2000)], speakers: speakers, rosterBase: nil)
        let closed = try GuideGaps.find(questions: twoSections(1, 1), cells: extraction.cells, furthestIndex: 1,
                                        currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(closed.map(\.state), [.skipped])
    }

    // MARK: Selection

    func testPendingQuestionsAreExcluded() throws {
        let questions = try twoSections(1, 3)
        let cells = try questions.map { try cell($0.qid) }
        let result = GuideGaps.find(questions: questions, cells: cells, furthestIndex: 1, currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(result.map(\.qid), ["S1Q1"])
        XCTAssertTrue(GuideGaps.find(questions: questions, cells: cells, furthestIndex: 0, currentQID: "S1Q1", rosterSize: nil).isEmpty)
    }

    func testPassedQuestionWithNoCoverageIsSkipped() throws {
        let result = try GuideGaps.find(questions: twoSections(1, 1), cells: [cell("S1Q1"), cell("S2Q1")], furthestIndex: 1,
                                        currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(result, [GuideGap(qid: "S1Q1", title: "Question 1.1?", titleZH: "问题1.1？", state: .skipped)])
        XCTAssertEqual(result.first?.detail, "Skipped")
    }

    func testUnaskedQuestionIsNotSkippedWhileItsSectionIsOpen() throws {
        // Moderators reorder inside a section: S1Q1 is no gap until S1 closes.
        let cells = try (1 ... 4).map { try cell("S1Q\($0)") }
        XCTAssertTrue(try gaps(cells, furthest: 1, current: "S1Q2").isEmpty)
        let questions = try twoSections(2, 1)
        let closed = GuideGaps.find(questions: questions, cells: [], furthestIndex: 2, currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(closed.map(\.qid), ["S1Q2", "S1Q1"])
    }

    func testQuestionsBeforeTheRecordingAreNotRecordedAndNeverActionable() throws {
        // The recording reached the guide at S1Q3: S1Q1 and S1Q2 were asked before Record.
        let questions = try twoSections(3, 1)
        let actionable = GuideGaps.find(questions: questions, cells: [], furthestIndex: 3, currentQID: "S2Q1",
                                        rosterSize: nil, recordedFromIndex: 2)
        XCTAssertEqual(actionable.map(\.qid), ["S1Q3"])
        XCTAssertTrue(actionable.allSatisfy(\.isActionable))
        let all = GuideGaps.find(questions: questions, cells: [], furthestIndex: 3, currentQID: "S2Q1",
                                 rosterSize: nil, recordedFromIndex: 2, includeNotRecorded: true)
        XCTAssertEqual(all.map(\.qid), ["S1Q3", "S1Q2", "S1Q1"])
        XCTAssertEqual(all.map(\.detail), ["Skipped", "Not recorded", "Not recorded"])
        XCTAssertFalse(all[1].isActionable)
    }

    func testAnEarlySkipInsideTheFirstSectionStaysAGap() throws {
        // A normal start: the moderator skipped S1Q1 and the guide reached
        // S1Q3 at minute 1. That is a skip, not a late start.
        let questions = try twoSections(3, 1)
        XCTAssertEqual(GuideGaps.recordedFrom(questions: questions, firstReachedIndex: 2), 0)
        let gaps = GuideGaps.find(questions: questions, cells: [], furthestIndex: 3, currentQID: "S2Q1", rosterSize: nil,
                                  recordedFromIndex: GuideGaps.recordedFrom(questions: questions, firstReachedIndex: 2))
        XCTAssertEqual(gaps.map(\.qid), ["S1Q3", "S1Q2", "S1Q1"])
        XCTAssertTrue(gaps.allSatisfy(\.isActionable), "a real skip keeps its Go back to")
        // A recording that first reached S2 started mid-guide: all of S1 was before Record.
        XCTAssertEqual(GuideGaps.recordedFrom(questions: questions, firstReachedIndex: 3), 3)
        XCTAssertEqual(GuideGaps.recordedFrom(questions: questions, firstReachedIndex: nil), 0)
    }

    func testModeratorInstructionItemsAreNeverGaps() throws {
        let json: [String: Any] = ["title": "Invented guide", "sections": [
            ["id": "S1", "title": "Section 1", "questions": [
                ["qid": "S1Q1", "en": "Moderator to hand out the stimulus cards", "zh": "主持人发放卡片", "probes": []],
                ["qid": "S1Q2", "en": "What do you see first?", "zh": "你先看到什么？", "probes": []],
            ]],
            ["id": "S2", "title": "Section 2", "questions": [["qid": "S2Q1", "en": "Next?", "zh": "", "probes": []]]],
        ]]
        let questions = try GuideDocument.parse(JSONSerialization.data(withJSONObject: json)).questions
        let result = GuideGaps.find(questions: questions, cells: [], furthestIndex: 2, currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(result.map(\.qid), ["S1Q2"])
    }

    func testCurrentQuestionIsNeverFlagged() throws {
        // A manual jump back makes an earlier question current while furthestIndex stays ahead.
        let questions = try twoSections(3, 1)
        let cells = try questions.map { try cell($0.qid) }
        let result = GuideGaps.find(questions: questions, cells: cells, furthestIndex: 3, currentQID: "S1Q2", rosterSize: nil)
        XCTAssertEqual(result.map(\.qid), ["S1Q3", "S1Q1"])
    }

    func testUnseatedQuotesCountInQuotesNotPeople() throws {
        let one = try gaps([cell("S1Q1", "Answered", quotes: 1)], furthest: 1, current: "S1Q2")
        XCTAssertEqual(one.map(\.state), [.thin(quotes: 1)])
        XCTAssertEqual(one.first?.detail, "Thin: 1 quote")
        XCTAssertFalse(one.first?.detail.contains("people") ?? true)
        XCTAssertTrue(try gaps([cell("S1Q1", "Answered", quotes: 2)], furthest: 1, current: "S1Q2").isEmpty)
    }

    func testCapAndMostRecentlyPassedFirst() throws {
        let questions = try twoSections(7, 1)
        let cells = try questions.map { try cell($0.qid) }
        let result = GuideGaps.find(questions: questions, cells: cells, furthestIndex: 7, currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(result.map(\.qid), ["S1Q7", "S1Q6", "S1Q5", "S1Q4", "S1Q3"])
        XCTAssertEqual(GuideGaps.limit, 5)
    }

    func testMissingCellCountsAsSkippedAndChineseOnlyTitleIsKept() throws {
        let json: [String: Any] = ["title": "Invented guide", "sections": [["id": "S1", "title": "Section 1", "questions": [
            ["qid": "S1Q1", "en": "", "zh": "你怎么洗杯子？", "probes": []],
        ]], ["id": "S2", "title": "Section 2", "questions": [
            ["qid": "S2Q1", "en": "Next?", "zh": "", "probes": []],
        ]]]]
        let questions = try GuideDocument.parse(JSONSerialization.data(withJSONObject: json)).questions
        let result = GuideGaps.find(questions: questions, cells: [], furthestIndex: 1, currentQID: "S2Q1", rosterSize: nil)
        XCTAssertEqual(result, [GuideGap(qid: "S1Q1", title: "你怎么洗杯子？", titleZH: nil, state: .skipped)])
    }
}
