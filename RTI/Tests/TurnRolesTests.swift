import RTICore
import XCTest

/// The shared role rule (P1), the tolerant guide-pass decode (P2) and the
/// spoken hand tally (P8). All text is invented.
final class TurnRolesTests: XCTestCase {
    private func guide() throws -> GuideDocument {
        let json: [String: Any] = ["title": "Invented oat drink group", "sections": [
            ["id": "S1", "title": "Warm-up", "minutes": 10, "questions": [
                ["qid": "S1Q1", "en": "How do you usually start your morning?", "zh": "你们平时早上一般怎么开始一天？", "probes": []],
                ["qid": "S1Q2", "en": "Moderator to hand out the drink cards", "zh": "主持人发放饮品卡片", "probes": []],
            ]],
            ["id": "S2", "title": "Face routine", "minutes": 20, "questions": [
                ["qid": "S2Q1", "en": "Which drink would you pick, A or B?", "zh": "你们会选哪一款饮品，A还是B？", "probes": []],
                ["qid": "S2Q2", "en": "What do you look for in a breakfast drink?", "zh": "早餐饮品你们最看重什么？", "probes": []],
            ]],
            ["id": "S3", "title": "Body routine", "minutes": 20, "questions": [
                ["qid": "S3Q1", "en": "What do you look for in a breakfast drink?", "zh": "早餐饮品你们最看重什么？", "probes": []],
            ]],
        ]]
        return try GuideDocument.parse(JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Role hint

    func testRoleHintReadsQuestionsSummariesAndGuideWordingAsModerator() throws {
        let context = try TurnRoles.Context(matcher: GuideMatcher(guide: guide()))
        func role(_ text: String, _ speaker: String = "remote") -> SpeechRole {
            TurnRoles.role(speaker: speaker, text: text, context: context)
        }
        XCTAssertEqual(role("那你们觉得这个味道怎么样？"), .moderator, "a question on the system leg")
        XCTAssertEqual(role("你会每天喝吗"), .moderator, "a 吗 question with no mark")
        XCTAssertEqual(role("所以大家都觉得太甜了，对吧"), .moderator, "a restating summary")
        XCTAssertEqual(role("选B的举手，一二三四五，五位"), .moderator, "a hand count")
        XCTAssertEqual(role("早餐饮品你们最看重的是什么，说说看"), .moderator, "close paraphrase of a guide question")
        XCTAssertEqual(role("对对对"), .unknown, "a bare yes is no evidence")
        XCTAssertEqual(role("我还没试过呢。"), .respondent, "呢 after a full stop is a statement")
        XCTAssertEqual(role("挺好的呢。"), .respondent)
        XCTAssertEqual(role("挺好的呢"), .respondent, "呢 alone never makes a question")
        XCTAssertEqual(role("那价格呢？"), .moderator, "the question mark decides")
        XCTAssertEqual(role("你们喝过这个吗。"), .moderator, "吗 before a full stop is still a question")
        XCTAssertEqual(role("我一般早上喝燕麦奶，因为不太甜。"), .respondent)
        XCTAssertEqual(role("I usually skip breakfast.", "remote_2"), .respondent)
        XCTAssertEqual(role("我一般早上喝燕麦奶。", "self"), .moderator, "the mic leg")
        let assigned = TurnRoles.Context(moderatorSpeakers: ["remote_3"])
        XCTAssertEqual(TurnRoles.role(speaker: "remote_3", text: "我觉得还行。", context: assigned), .moderator)
    }

    func testRespondentEchoingAFewGuideWordsInALongAnswerStaysRespondent() throws {
        let matcher = try GuideMatcher(guide: guide())
        XCTAssertFalse(matcher.matches("我最看重什么呢就是口感要顺滑，然后不能太甜，早上喝完不会觉得腻，还有包装要方便带去公司。"))
    }

    // MARK: Split

    func testMergedQuestionAndAnswerSplitAtTheQuestionMark() {
        let pieces = TurnRoles.splitAtQuestions("你平时早上喝什么？我一般喝燕麦奶。")
        XCTAssertEqual(pieces.map(\.text), ["你平时早上喝什么？", "我一般喝燕麦奶。"])
        XCTAssertEqual(pieces.map(\.offset), [0, 9])
        XCTAssertEqual(TurnRoles.splitAtQuestions("真的吗？？").map(\.text), ["真的吗？？"], "a trailing mark splits nothing")
        XCTAssertEqual(TurnRoles.splitAtQuestions("Why? Because it is light.").map(\.text), ["Why?", "Because it is light."])
        XCTAssertEqual(TurnRoles.splitAtQuestions("No question here.").count, 1)
    }

    // MARK: Echo

    private func spoken(_ id: String, _ speaker: String, _ start: Int, _ end: Int, _ text: String) -> TurnRoles.Spoken {
        TurnRoles.Spoken(id: id, speaker: speaker, startMs: start, endMs: end, text: text)
    }

    func testRemoteEnglishInterviewDropsNoModeratorQuestion() {
        // A remote IDI: the respondent on the system leg, the moderator on the
        // mic, each question right after an answer that shares its words.
        let turns = [
            spoken("r1", "remote", 0, 5000, "The main reason is that the location is close and the staff are friendly."),
            spoken("m1", "self", 5200, 6500, "Is that the main reason?"),
            spoken("r2", "remote", 6800, 12000, "So it is the location and the staff, mostly the staff, I think."),
            spoken("m2", "self", 12100, 14000, "So it is the location and the staff then?"),
            spoken("r3", "remote", 14300, 19000, "Tell me more about the weekends? The weekends are busy, I go with my family."),
            spoken("m3", "self", 19100, 21000, "Tell me more about the weekends."),
            spoken("r4", "remote", 21200, 26000, "It feels fair to me, that's what makes it feel fair, the price is clear."),
            spoken("m4", "self", 26100, 29000, "That's interesting, what makes it feel fair to you?"),
            spoken("r5", "remote", 29200, 33000, "我觉得这个价格还算合理，因为量比较大。"),
            spoken("m5", "self", 33100, 35000, "所以你觉得价格合理，因为量比较大？"),
        ]
        XCTAssertFalse(TurnRoles.roomOnBothLegs(turns), "a remote call never shows the room on both legs")
        XCTAssertTrue(TurnRoles.micEchoIDs(turns, against: turns).isEmpty)
        // Even with a room sample that passes the gate, a question asked after
        // the answer does not overlap it and stays.
        let room = (0 ..< 3).flatMap { index -> [TurnRoles.Spoken] in
            let start = 100_000 + index * 10000
            return [spoken("room\(index)", "remote", start, start + 4000, "我觉得这个包装很好看，颜色也很清爽，第\(index)位。"),
                    spoken("echo\(index)", "self", start + 300, start + 4200, "我觉得这个包装很好看颜色也很清爽第\(index)位")]
        }
        XCTAssertTrue(TurnRoles.micEchoIDs(turns, against: turns, roomSample: room).isEmpty)
    }

    func testInRoomGroupHeardOnASpeakerDropsOnlyTheEchoes() {
        // The room plays on a speaker: the mic hears the same words at the same time.
        var turns: [TurnRoles.Spoken] = []
        let lines = ["我觉得这个包装很好看，颜色也很清爽。", "早上我一般喝燕麦奶，不太甜。", "价格的话我觉得有点贵。", "I usually buy it at the supermarket near my office."]
        for (index, line) in lines.enumerated() {
            let start = index * 10000
            turns.append(spoken("r\(index)", "remote", start, start + 4000, line))
            turns.append(spoken("e\(index)", "self", start + 250, start + 4200, line.replacingOccurrences(of: "，", with: "")))
        }
        let own = spoken("own", "self", 41000, 43000, "Let's note the packaging point for the client.")
        let late = spoken("late", "self", 60000, 63000, "我觉得这个包装很好看颜色也很清爽")
        turns += [own, late]
        XCTAssertTrue(TurnRoles.roomOnBothLegs(turns))
        XCTAssertEqual(TurnRoles.micEchoIDs(turns, against: turns), ["e0", "e1", "e2", "e3"],
                       "the user's own line and a repeat with no room speech under it stay")
        XCTAssertTrue(TurnRoles.micEchoIDs([own], against: [own]).isEmpty, "a mic-only call drops nothing")
    }

    func testEchoPairsAreWordPairsInEnglishAndCharacterPairsInChinese() {
        XCTAssertEqual(TurnRoles.echoPairs("Is that the main reason?"), ["is that", "that the", "the main", "main reason"])
        XCTAssertEqual(TurnRoles.echoPairs("That's fair"), ["thats fair"], "an apostrophe stays inside its word")
        XCTAssertEqual(TurnRoles.echoPairs("我选B吧"), ["我 选", "选 b", "b 吧"])
    }

    // MARK: Guide position

    func testModeratorLineEstablishesTheQuestionAndRepeatedBlocksResolveForward() throws {
        let matcher = try GuideMatcher(guide: guide())
        XCTAssertEqual(matcher.question(asked: "好，那我们来看一下，你们会选哪一款饮品，A还是B？", near: 0), "S2Q1")
        XCTAssertEqual(matcher.question(asked: "早餐饮品你们最看重什么？", near: 2), "S2Q2", "the face block, nearest ahead")
        XCTAssertEqual(matcher.question(asked: "早餐饮品你们最看重什么？", near: 4), "S3Q1", "the body block once in S3")
        XCTAssertNil(matcher.question(asked: "主持人发放饮品卡片", near: 0), "an instruction item never establishes a position")
    }

    // MARK: Tolerant decode

    func testSuggestionDecodesAsStringObjectOrNullAndABadFieldNeverDropsTheCells() throws {
        func decode(_ json: String) throws -> GuidePass {
            try JSONDecoder().decode(GuidePass.self, from: Data(json.utf8))
        }
        let cells = #"[{"qid":"S2Q1","coverage":"Answered","summary":"Most picked B.","turns":["t1"],"quotes":[{"turn":"t1","english":"B."}]}]"#
        XCTAssertEqual(try decode(#"{"suggestion":"S2Q1","evidence":["t0"],"cells":\#(cells)}"#).suggestion, "S2Q1")
        let object = try decode(#"{"suggestion":{"qid":"S2Q1","ids":["t0","t1"]},"evidence":["t0"],"cells":\#(cells)}"#)
        XCTAssertEqual(object.suggestion, "S2Q1")
        XCTAssertEqual(object.evidence, ["t0", "t1"], "ids lift into evidence once each")
        let null = try decode(#"{"suggestion":null,"cells":\#(cells)}"#)
        XCTAssertNil(null.suggestion)
        XCTAssertEqual(null.evidence, [])
        XCTAssertEqual(null.cells.first?.votes.count, 0, "votes default to empty")

        let messy = try decode(#"""
        {"suggestion":{"turn":"t9"},"evidence":"t1","cells":[
          {"qid":"S2Q1","coverage":"Answered","summary":"Most picked B.","turns":["t1",7],"quotes":[{"english":"no turn"},{"turn":"t1","english":"B."}],"votes":{"bad":1}},
          {"coverage":"Answered"},
          {"qid":"S2Q2","turns":["t2"]}
        ]}
        """#)
        XCTAssertNil(messy.suggestion, "an object without a qid is no suggestion")
        XCTAssertEqual(messy.evidence, [])
        XCTAssertEqual(messy.cells.map(\.qid), ["S2Q1", "S2Q2"], "a cell with no qid drops alone")
        XCTAssertEqual(messy.cells[0].turns, ["t1"])
        XCTAssertEqual(messy.cells[0].quotes.map(\.turn), ["t1"])
        XCTAssertEqual(messy.cells[0].votes.count, 0)
        XCTAssertEqual(messy.cells[1].coverage, "Lightly covered")
        XCTAssertEqual(messy.cells[1].summary, "")
        XCTAssertFalse(messy.isEmpty)
        XCTAssertTrue(try decode(#"{"suggestion":null,"evidence":[],"cells":[]}"#).isEmpty)
    }

    // MARK: Hand tally

    func testSpokenHandTallyBecomesAVoteRecordAndOldCellsStillLoad() throws {
        let guide = try guide()
        var extraction = GuideExtraction(group: "G1", transcript: "transcript.live.md", guide: guide)
        let tally = GuideTurn(id: "self@60000", speaker: "self", startMs: 60000, text: "选B的举手，一二三四五，五位。选A的呢？一位。")
        let answer = GuideTurn(id: "remote@58000", speaker: "remote", startMs: 58000, text: "我会选B，看起来更清爽。")
        let question = GuideTurn(id: "remote@57000", speaker: "remote", startMs: 57000, text: "你们会选哪一款饮品，A还是B？")
        let pass = try JSONDecoder().decode(GuidePass.self, from: Data(#"""
        {"suggestion":"S2Q1","evidence":[],"cells":[{"qid":"S2Q1","coverage":"Answered","summary":"Most chose B for a lighter look.",
         "turns":["remote@57000","remote@58000","self@60000"],
         "quotes":[{"turn":"remote@57000","english":"Which would you pick?"},{"turn":"remote@58000","english":"I'd pick B, it looks lighter."}],
         "votes":[{"turn":"self@60000","choice":"B","count":5,"source":"moderator_tally"},{"turn":"self@60000","choice":"A","count":"1"},
                  {"turn":"remote@58000","choice":"B","count":3}]}]}
        """#.utf8))
        extraction.apply(pass, turns: [question, answer, tally], speakers: [:], rosterBase: nil, moderatorTurns: ["remote@57000"])
        let cell = try XCTUnwrap(extraction.cells.first { $0.qid == "S2Q1" })
        XCTAssertEqual(cell.orderedQuotes.map(\.turnID), ["remote@58000"], "the moderator's question is never a quote")
        XCTAssertEqual(cell.tally, "1 chose A; 5 chose B (show of hands)", "a count on a respondent's line is no tally")
        XCTAssertTrue(cell.hasHandTally)
        XCTAssertEqual(cell.coverage, "Answered")

        // Round trip, and an archive written before tallies existed still loads.
        let data = try JSONEncoder().encode(extraction)
        XCTAssertEqual(try JSONDecoder().decode(GuideExtraction.self, from: data), extraction)
        let old = #"{"qid":"S2Q1","coverage":"Lightly covered","summary":"","quotes":[],"tally":null,"score":null,"who":"","note_evidence":[],"vote_evidence":[{"turn":"t1","speaker":"remote","choice":"A"}]}"#
        let oldCell = try JSONDecoder().decode(GuideCell.self, from: Data(old.utf8))
        XCTAssertFalse(oldCell.hasHandTally)
    }

    func testSeatPicksStayVisibleBesideAHandTally() throws {
        var extraction = try GuideExtraction(group: "G1", transcript: "transcript.live.md", guide: guide())
        let tally = GuideTurn(id: "self@60000", speaker: "self", startMs: 60000, text: "选B的举手，一二三四五，五位。")
        let pick = GuideTurn(id: "remote_2@58000", speaker: "remote_2", startMs: 58000, text: "我选B。")
        let speakers = ["remote_2": GuideSpeaker(participant: "R2", seatCode: "R2")]
        let pass = try JSONDecoder().decode(GuidePass.self, from: Data(#"""
        {"suggestion":null,"evidence":[],"cells":[{"qid":"S2Q1","coverage":"Lightly covered","summary":"Most chose B.",
         "turns":["remote_2@58000","self@60000"],"quotes":[],
         "votes":[{"turn":"self@60000","choice":"B","count":5},{"turn":"remote_2@58000","choice":"B"}]}]}
        """#.utf8))
        extraction.apply(pass, turns: [pick, tally], speakers: speakers, rosterBase: 6)
        let cell = try XCTUnwrap(extraction.cells.first { $0.qid == "S2Q1" })
        XCTAssertEqual(cell.tally, "5 chose B (show of hands). Named picks: 1 of 6 chose B")
    }
}
