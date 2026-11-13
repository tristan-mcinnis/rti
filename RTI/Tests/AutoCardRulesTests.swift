import RTICore
import XCTest

/// The code-side Auto rules (P4 to P7): the Mandarin window and line, pinyin,
/// near repeats, one card per research pass, RECALL with a source, the
/// research format, thin respondent input and the signals. Invented text only.
final class AutoCardRulesTests: XCTestCase {
    private let citation = VaultSearch.citations(for: [
        VaultSearch.Result(title: "Fixture round 1", relativePath: "projects/fixture/round-1.md",
                           modified: Date(timeIntervalSince1970: 1_700_000_000), excerpt: "Oat drink notes.", score: 10),
    ])

    private func card(_ kind: AutoCardKind, _ text: String, zh: String? = nil, why: String = "",
                      cited: Bool = false) -> AutoAssistCard
    {
        AutoAssistCard(timestamp: Date(timeIntervalSince1970: 1_800_000_000), kind: kind, text: text, textZH: zh,
                       why: why, citation: cited ? citation.first : nil)
    }

    // MARK: - Language

    func testCJKShareCountsLettersAndCharactersOnly() {
        XCTAssertEqual(AutoCardLanguage.cjkShare("Hello there"), 0)
        XCTAssertEqual(AutoCardLanguage.cjkShare("我早上喝燕麦奶"), 1)
        XCTAssertEqual(AutoCardLanguage.cjkShare("123 ?!"), 0)
        XCTAssertTrue(AutoCardLanguage.isMandarin("我觉得 the price 有点贵，不太划算。"))
        XCTAssertFalse(AutoCardLanguage.isMandarin("We tested the oat drink with six people today, 好。"))
    }

    func testPinyinIsToneMarkedAndOnlyForHan() throws {
        let pinyin = try XCTUnwrap(AutoCardLanguage.pinyin("为什么这个对你重要？"))
        XCTAssertTrue(pinyin.contains("wèi") || pinyin.contains("wéi"), pinyin)
        XCTAssertTrue(pinyin.contains("zhòng"), pinyin)
        XCTAssertNil(AutoCardLanguage.pinyin("Why does that matter?"))
        XCTAssertNil(AutoCardLanguage.pinyin(nil))
        let made = card(.ask, "Why does this matter to you?", zh: "为什么这个对你重要？")
        XCTAssertNotNil(made.pinyin, "a card makes its pinyin once, when built")
        XCTAssertEqual(made.speakable, "为什么这个对你重要？")
        XCTAssertNil(card(.ask, "Same line", zh: " Same line ").textZH, "a Mandarin field that repeats the English is no line")
    }

    func testTheWireShapeReadsTextEnAndTextZhAndTheOlderText() {
        let json = #"""
        {"cards":[
          {"kind":"ASK","text_en":"Who sees it differently?","text_zh":"有没有人不一样的看法？","why":"One view so far.","source":null},
          {"kind":"SAY","text":"An older saved prompt.","why":"Old shape."},
          {"kind":"ASK","text_zh":"大家说的清爽是指什么？"},
          {"kind":"ASK","why":"No line at all."}
        ]}
        """#
        let items = JSONExtractor.decodeArrayLenient(json, key: "cards", as: AutoCardItem.self)
        let cards = items.compactMap { AutoAssistCard.make(from: $0, citations: []) }
        XCTAssertEqual(cards.map(\.text), ["Who sees it differently?", "An older saved prompt.", "大家说的清爽是指什么？"])
        XCTAssertEqual(cards[0].textZH, "有没有人不一样的看法？")
        XCTAssertNil(cards[1].textZH)
        XCTAssertEqual(cards[2].textZH, "大家说的清爽是指什么？", "a Mandarin-only card keeps its Mandarin line")
    }

    func testAMandarinOnlyLineSurvivesAMandarinWindow() throws {
        let json = #"""
        {"cards":[
          {"kind":"ASK","text_en":"","text_zh":"为什么这个对你重要？"},
          {"kind":"ASK","text_en":"有没有人不一样的看法？","text_zh":null},
          {"kind":"SAY","text_en":"有没有人不一样的看法？","text_zh":"有没有人不一样的看法？"},
          {"kind":"ASK","text_en":"Probe the word 清爽 they used","text_zh":null}
        ]}
        """#
        let items = JSONExtractor.decodeArrayLenient(json, key: "cards", as: AutoCardItem.self)
        let cards = items.compactMap { AutoAssistCard.make(from: $0, citations: []) }
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards[0].textZH, "为什么这个对你重要？")
        XCTAssertNotNil(cards[0].pinyin)
        XCTAssertEqual(cards[1].textZH, "有没有人不一样的看法？", "a Mandarin line in the English field is the Mandarin line")
        XCTAssertEqual(cards[2].textZH, "有没有人不一样的看法？")
        XCTAssertNil(cards[3].textZH, "an English line naming one Chinese word is no Mandarin line")
        let kept = AutoCardRules.accept([cards[0], cards[3]], callType: .client, mandarin: true, recent: [])
        XCTAssertEqual(kept.map(\.text), ["为什么这个对你重要？"])
        XCTAssertEqual(try XCTUnwrap(kept.first).speakable, "为什么这个对你重要？")
        let research = AutoCardRules.accept([cards[1]], callType: .research, mandarin: true, recent: [])
        XCTAssertEqual(research.count, 1)
    }

    func testAnOlderSavedPromptsThreeLineTextSplitsIntoItsLines() throws {
        // The old shape: one "text" with the English, the Mandarin and the pinyin.
        let json = #"""
        {"cards":[
          {"kind":"ASK","text":"Ask what fresh means to them\n大家说的清爽是指什么？\ndàjiā shuō de qīngshuǎng shì zhǐ shénme?","why":"Old shape."}
        ]}
        """#
        let items = JSONExtractor.decodeArrayLenient(json, key: "cards", as: AutoCardItem.self)
        let card = try XCTUnwrap(items.compactMap { AutoAssistCard.make(from: $0, citations: []) }.first)
        XCTAssertEqual(card.text, "Ask what fresh means to them")
        XCTAssertEqual(card.textZH, "大家说的清爽是指什么？")
        XCTAssertEqual(AutoCardRules.accept([card], callType: .research, mandarin: true, recent: []).count, 1,
                       "an older saved prompt still shows its SAY and ASK cards in a Mandarin window")
        XCTAssertEqual(AutoCardLanguage.lines(english: "Confirm the date", mandarin: nil).textZH, nil)
    }

    // MARK: - Repeats

    func testJaccardUsesWordsAndCharacterPairs() {
        XCTAssertGreaterThanOrEqual(AutoCardRules.jaccard("Ask who signs off on the budget", "Ask who signs off the budget"), 0.5)
        XCTAssertLessThan(AutoCardRules.jaccard("Ask who signs off on the budget", "Probe the word fresh"), 0.5)
        XCTAssertGreaterThanOrEqual(AutoCardRules.jaccard("有没有人不一样的看法", "有没有人有不一样的看法"), 0.5)
        XCTAssertLessThan(AutoCardRules.jaccard("有没有人不一样的看法", "为什么这个对你重要"), 0.5)
        XCTAssertEqual(AutoCardRules.units("好"), ["好"])
    }

    func testANearRepeatOfARecentCardIsDropped() {
        let recent = [card(.ask, "Ask the room who sees it differently", zh: "有没有人不一样的看法？")]
        let kept = AutoCardRules.accept([
            card(.ask, "Ask who in the room sees it differently", zh: "有没有人有不一样的看法？"),
            card(.ask, "Probe what fresh means to them", zh: "大家说的清爽是指什么？"),
        ], callType: .client, mandarin: true, recent: recent)
        XCTAssertEqual(kept.map(\.text), ["Probe what fresh means to them"])
    }

    // MARK: - What a pass may show

    func testRecallNeedsASuppliedSource() {
        let kept = AutoCardRules.accept([card(.recall, "Round 1 said price was fine."),
                                         card(.recall, "Round 1 said the cap leaks.", cited: true)],
                                        callType: .client, mandarin: false, recent: [])
        XCTAssertEqual(kept.map(\.text), ["Round 1 said the cap leaks."])
    }

    func testWithNoGuideACardNeverNamesAGuide() {
        let batch = [card(.flag, "The guide's price probe was skipped."), card(.ask, "Go back to the 提纲 question", zh: "回到提纲的问题。"),
                     card(.flag, "Leading question at 03:10", why: "Some guidance on wording.")]
        XCTAssertEqual(AutoCardRules.accept(batch, callType: .client, mandarin: false, recent: [], guideActive: false).map(\.text),
                       ["Leading question at 03:10"], "guidance is no guide")
        XCTAssertEqual(AutoCardRules.accept(batch, callType: .client, mandarin: false, recent: [], guideActive: true).count, 3)
        XCTAssertTrue(AutoCardRules.mentionsGuide(card(.flag, "Guides differ")))
        XCTAssertFalse(AutoCardRules.mentionsGuide(card(.flag, "Guidelines say otherwise")))
    }

    func testAMandarinWindowDropsSayAndAskWithoutTheMandarinLine() {
        let batch = [card(.ask, "Ask what fresh means"), card(.flag, "Leading question at 03:10"),
                     card(.say, "Confirm the date", zh: "我们确认一下日期。")]
        XCTAssertEqual(AutoCardRules.accept(batch, callType: .client, mandarin: true, recent: []).map(\.text),
                       ["Leading question at 03:10", "Confirm the date"])
        XCTAssertEqual(AutoCardRules.accept(batch, callType: .client, mandarin: false, recent: []).count, 3)
    }

    func testAResearchPassShowsOneCardUnlessAContradictionComes() {
        let probe = card(.ask, "Ask what fresh means", zh: "大家说的清爽是指什么？")
        let second = card(.ask, "Ask about price", zh: "价格怎么看？")
        let plainFlag = card(.flag, "Leading question", why: "选A还是选B")
        let contradiction = card(.flag, "Sweetness flipped", why: "08:12 太甜了 vs 34:05 甜度刚好")
        XCTAssertEqual(AutoCardRules.accept([probe, second, plainFlag, contradiction], callType: .research,
                                            mandarin: true, recent: []).map(\.text),
                       ["Ask what fresh means", "Sweetness flipped"])
        XCTAssertEqual(AutoCardRules.accept([probe, second], callType: .client, mandarin: true, recent: []).count, 2,
                       "a client pass may offer more than one")
        XCTAssertTrue(AutoCardRules.isContradiction(contradiction))
        XCTAssertFalse(AutoCardRules.isContradiction(card(.flag, "At 08:12 only")))
        XCTAssertFalse(AutoCardRules.isContradiction(card(.ask, "08:12 vs 34:05")), "only a FLAG")
    }

    // MARK: - Research format and thin input

    func testResearchFormatFromRosterThenTitle() {
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 6, guideTitle: nil), .group)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 1, guideTitle: "FGD guide"), .interview)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "Oat drink FGD"), .group)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "燕麦奶深访"), .interview)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "Mock study"), .unknown)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "Oat drink IDI 3"), .interview)
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "IDI-2 coffee"), .interview)
        for title in ["Coffee acidity check", "Humidity and skin", "Claim validity"] {
            XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: title), .unknown, "\(title): idi only as a word")
        }
        XCTAssertEqual(ResearchFormat.infer(rosterCount: 0, guideTitle: "Group interview, round 2"), .group)
        XCTAssertEqual(ResearchFormat.interview.minimumRespondentCharacters, 40)
        XCTAssertEqual(ResearchFormat.group.minimumRespondentCharacters, 150)
    }

    func testRespondentCharactersSkipModeratorLinesAndTheMicWhenThereIsASystemLeg() {
        let context = TurnRoles.Context()
        let turns: [(isThem: Bool, text: String)] = [
            (true, "你平时早上喝什么？"),
            (true, "我一般喝燕麦奶"),
            (true, "嗯"),
            (false, "我自己也喝燕麦奶"),
        ]
        XCTAssertEqual(AutoResearchSignals.respondentCharacters(turns, sessionHasThem: true, context: context), 7)
        XCTAssertEqual(AutoResearchSignals.respondentCharacters(turns, sessionHasThem: false, context: context), 15,
                       "a room heard only on the mic is read by its words")
    }

    // MARK: - Signals

    func testSilenceSignalAfterThreeMinutes() {
        XCTAssertNil(AutoResearchSignals.silence(lastThemMs: 60000, latestMs: 200_000))
        let line = AutoResearchSignals.silence(lastThemMs: 60000, latestMs: 300_000)
        XCTAssertEqual(line, "No Them speech for 4 min (since 1:00): the other side's audio may have dropped.")
        XCTAssertNil(AutoResearchSignals.silence(lastThemMs: nil, latestMs: 300_000), "no Them speech yet is not a drop")
    }

    func testOverrunNamesOpenQuestionsAndBudgetsAreStable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("GuideFixtures/dg-questions.json")
        let guide = try GuideDocument.parse(Data(contentsOf: url))
        let section = try XCTUnwrap(guide.sections.first)
        XCTAssertNil(AutoResearchSignals.overrun(section: section, elapsed: 5 * 60, openQIDs: ["S1Q2"]))
        let line = try XCTUnwrap(AutoResearchSignals.overrun(section: section, elapsed: 9 * 60, openQIDs: ["S1Q2"]))
        XCTAssertTrue(line.hasPrefix("Section S1 "), line)
        XCTAssertTrue(line.contains("has run 9 min of its 6 min budget; open questions at risk: S1Q2."), line)
        XCTAssertEqual(AutoResearchSignals.budgets(guide).count, guide.sections.filter { $0.minutes != nil }.count)
    }
}
