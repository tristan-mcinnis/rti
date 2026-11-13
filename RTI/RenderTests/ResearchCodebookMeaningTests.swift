import Foundation
import RTICore
import XCTest

/// The codebook as a list of meanings (schema 2): emic names with a gloss,
/// merge before create, no people, votes, tensions with both sides,
/// hypotheses for and against, client questions, the ten-minute synthesis
/// and the brief. All text is invented: an oat drink, Lumo 露慕.
@MainActor
final class ResearchCodebookMeaningTests: XCTestCase {
    private func quote(_ id: String, _ minute: Double, _ original: String, moderator: Bool = false,
                       session: String = "s1", codes: [String]? = nil) -> ResearchQuote
    {
        ResearchQuote(sessionID: session, turnID: id, group: "G1", offsetMs: Int(minute * 60000), original: original,
                      speaker: .init(rawSpeaker: moderator ? "self" : "remote", label: moderator ? "Me" : "Them",
                                     leg: moderator ? "Me" : "Them", confidence: "legOnly", seat: nil, segment: nil, moderator: moderator),
                      questionID: "S2Q1", revealRecorded: false, mentionedCodes: codes)
    }

    private func entry(_ type: ResearchCardType, zh: String? = nil, en: String? = nil, code: String? = nil, turn: String,
                       counter: String? = nil, quote: String? = nil, point: String = "Shows the code.",
                       valence: ResearchValence = .neutral) -> ResearchProposal.Item
    {
        .init(code: code, nameZh: zh, nameEn: en, type: type, turnID: turn, counterTurnID: counter, qid: "S2Q1", quote: quote,
              point: point, valence: valence)
    }

    // MARK: - Old archives

    func testSchemaOneArchiveLoadsAndItsPeopleAreNotCodes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let evidence = """
        {"sessionID":"old","turnID":"t1","group":"G1","offsetMs":60000,"original":"我早上都喝燕麦奶。",
         "speaker":{"rawSpeaker":"remote_1","label":"Them","leg":"Them","confidence":"legOnly","moderator":false},"revealRecorded":false}
        """
        let json = """
        {"schemaVersion":1,"sessions":[{"id":"old","group":"G1","startedAt":0,"folder":"old","consumed":["t1"],"endMs":61000,"incomplete":false}],
         "cards":[
          {"id":"\(UUID().uuidString)","name":"remote_1","aliases":[],"type":"person","origin":"emerged","pinned":false,
           "entries":[{"point":"Drinks it daily.","valence":"positive","evidence":\(evidence)}]},
          {"id":"\(UUID().uuidString)","name":"Corner Shop","aliases":[],"type":"org","origin":"emerged","pinned":false,"entries":[]},
          {"id":"\(UUID().uuidString)","name":"Morning habit","aliases":[],"type":"concept","origin":"emerged","pinned":false,
           "entries":[{"point":"A morning ritual.","valence":"positive","evidence":\(evidence)}]}
         ],"suppressed":[],"redirects":{}}
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("codebook.json"))
        let book = try await ResearchCodebookStore().existingBook(in: folder)
        XCTAssertEqual(book.cards.map(\.type), [.person, .org, .concept], "old cards load as they were")
        XCTAssertEqual(book.schemaVersion, ResearchCodebook.currentSchema)
        let map = book.topicMap()
        XCTAssertEqual(map.sections.map(\.group), [.themes])
        XCTAssertEqual(map.sections[0].topics.map(\.name), ["Morning habit"])
        XCTAssertEqual(ResearchCodebookController.known(book, sessionID: "old").codes.map(\.nameEn), ["Morning habit"])
        XCTAssertEqual(ResearchCodebookController.known(book, sessionID: "old").codes.map(\.type), ["theme"])
        let markdown = ResearchCodebookStore.markdown(book)
        XCTAssertTrue(markdown.contains("## Morning habit"))
        XCTAssertFalse(markdown.contains("remote_1"), "a person card is not a code")
    }

    // MARK: - A pass

    func testAThemeKeepsTheEmicNameFirstWithAnEnglishGloss() throws {
        var book = ResearchCodebook()
        let one = quote("t1", 8, "我早上喝露慕就是图个省事，不用想。"), two = quote("t2", 9, "对我来说省事最重要，早上没时间。")
        book.apply(.init(entries: [
            entry(.theme, zh: "图个省事", en: "Wanting the morning to be effortless", turn: "t1", quote: "图个省事", valence: .positive),
            entry(.theme, zh: "图个省事", en: "Wanting the morning to be effortless", turn: "t2", quote: "not in the turn"),
        ], names: nil), sources: [one, two])
        let card = try XCTUnwrap(book.cards.first)
        XCTAssertEqual(book.cards.count, 1)
        XCTAssertEqual(card.name, "图个省事")
        XCTAssertEqual(card.gloss, "Wanting the morning to be effortless")
        XCTAssertEqual(card.quoteCount, 2)
        XCTAssertEqual(card.entries.map(\.excerpt), ["图个省事", nil], "an excerpt must be the respondent's exact words")
        XCTAssertEqual(card.provenance, .spontaneous)
        XCTAssertEqual(card.qids, ["S2Q1"])
        let topic = try XCTUnwrap(book.topicMap().sections.first?.topics.first)
        XCTAssertEqual(topic.name, "图个省事")
        XCTAssertEqual(topic.gloss, "Wanting the morning to be effortless")
        XCTAssertEqual(topic.spoken, "图个省事, Wanting the morning to be effortless, theme, 2 quotes, positive")
    }

    func testANewCodeNeedsTwoQuotesABrandOrABarrierAndAtMostThreeAPass() {
        var book = ResearchCodebook()
        book.seed("露慕 Lumo", type: .brand)
        let sources = (1 ... 12).map { quote("t\($0)", Double($0), "回答\($0)") }
            + [quote("b1", 20, "露慕 Lumo 的盒子太难打开。"), quote("f1", 21, "我怕喝了会胀气。")]
        book.apply(.init(entries: [
            entry(.theme, zh: "一句话", turn: "t1"),
            entry(.need, zh: "要提神", en: "Needs a lift", turn: "b1"),
            entry(.barrier, zh: "怕胀气", en: "Fear of bloating", turn: "f1"),
        ], names: nil), sources: sources)
        XCTAssertEqual(book.cards.map(\.name), ["露慕 Lumo", "要提神", "怕胀气"],
                       "one quote is not a code unless it names a brand or a fear or barrier")
        var capped = ResearchCodebook()
        let items = (1 ... 5).flatMap { n in [entry(.theme, zh: "主题\(n)", turn: "t\(2 * n - 1)"), entry(.theme, zh: "主题\(n)", turn: "t\(2 * n)")] }
        capped.apply(.init(entries: items, names: nil), sources: sources)
        XCTAssertEqual(capped.cards.map(\.name), ["主题1", "主题2", "主题3"], "at most three new non-brand codes a pass")
        capped.apply(.init(entries: [entry(.theme, zh: "主题1", turn: "t11")], names: nil), sources: sources)
        XCTAssertEqual(capped.cards[0].quoteCount, 3, "a known code takes one more quote")
    }

    func testABrandMadeInAPassNeverTakesAnotherBrandsSpelling() {
        var book = ResearchCodebook()
        let sources = [quote("t1", 1, "晴越比较淡。"), quote("t2", 2, "清悦和晴越不是一家，清悦是老牌子。")]
        book.apply(.init(entries: [
            entry(.brand, zh: "晴越", turn: "t1", point: "Milder.", valence: .positive),
            .init(nameZh: "清悦", type: .brand, aliases: ["晴越"], turnID: "t2", point: "An older brand."),
        ], names: nil), sources: sources)
        XCTAssertEqual(book.cards.map(\.name), ["晴越", "清悦"])
        XCTAssertEqual(book.cards.map(\.aliases), [[], []], "neither brand takes the other's name")
    }

    func testPeopleOrganisationsAndSpeakerLabelsNeverBecomeCodes() {
        var book = ResearchCodebook()
        let sources = [quote("t1", 1, "我觉得还行。"), quote("t2", 2, "还行吧。")]
        book.apply(.init(entries: [
            entry(.person, en: "Xiao He", turn: "t1"), entry(.person, en: "Xiao He", turn: "t2"),
            entry(.org, en: "Corner Shop", turn: "t1"), entry(.org, en: "Corner Shop", turn: "t2"),
            entry(.theme, en: "remote_1", turn: "t1"), entry(.theme, en: "remote_1", turn: "t2"),
            entry(.theme, en: "self", turn: "t1"), entry(.theme, en: "room 2", turn: "t2"),
            entry(.theme, zh: "小禾", turn: "t1"), entry(.theme, zh: "小禾", turn: "t2"),
        ], names: nil), sources: sources, forbidden: ["小禾"])
        XCTAssertTrue(book.cards.isEmpty, "\(book.cards.map(\.name))")
        XCTAssertTrue(ResearchCodebook.isSpeakerLabel("them_3"))
        XCTAssertTrue(ResearchCodebook.isSpeakerLabel("主持人"))
        XCTAssertFalse(ResearchCodebook.isSpeakerLabel("Remote work"))
    }

    func testSoundAlikeBrandsStayApartAndSpellingVariantsMerge() throws {
        var book = ResearchCodebook()
        book.seed("露慕 Lumo", type: .brand, pinned: true, client: true)
        book.seed("清悦", type: .brand)
        book.seed("晴越", type: .brand)
        let sources = [quote("t1", 1, "路慕那个燕麦奶我喝过。"), quote("t2", 2, "清悦太甜。"), quote("t3", 3, "晴越比较淡。"),
                       quote("t4", 4, "鹿慕也不错。")]
        let codes = ResearchCodebookController.known(book, sessionID: "s1").ids
        let lumo = try XCTUnwrap(codes.first { book.cards.first { $0.name == "露慕 Lumo" }?.id == $0.value }?.key)
        book.apply(.init(entries: [
            .init(code: lumo, nameZh: "露慕", type: .brand, aliases: ["路慕"], turnID: "t1", point: "Has tried it.", valence: .positive),
            entry(.brand, zh: "清悦", turn: "t2", point: "Too sweet.", valence: .negative),
            entry(.brand, zh: "晴越", turn: "t3", point: "Milder.", valence: .positive),
            .init(code: lumo, nameZh: "露慕", type: .brand, aliases: ["鹿慕", "清悦"], turnID: "t4", point: "Also fine.", valence: .positive),
        ], names: nil), sources: sources, codes: codes)
        XCTAssertEqual(book.cards.count, 3)
        let client = try XCTUnwrap(book.cards.first { $0.clientBrand == true })
        XCTAssertTrue(client.pinned)
        XCTAssertTrue(client.aliases.contains("路慕"))
        XCTAssertFalse(client.aliases.contains("清悦"), "a brand never absorbs another brand's name")
        XCTAssertEqual(client.entries.map(\.evidence.turnID), ["t1"], "an entry that would merge two brands is dropped")
        XCTAssertEqual(book.cards.first { $0.name == "清悦" }?.entries.count, 1)
        XCTAssertEqual(book.cards.first { $0.name == "晴越" }?.entries.count, 1)
    }

    func testModeratorLinesAreNeverEvidenceButATallyIsAVote() throws {
        var book = ResearchCodebook()
        let summary = quote("m1", 10, "所以大家都觉得太甜了，对吧？", moderator: true)
        let tally = quote("m2", 11, "选B的举手，一二三四五，五位。选A的呢？一位。", moderator: true)
        let reply = quote("t1", 10.2, "对对对。")
        book.apply(.init(entries: [
            entry(.theme, zh: "太甜", turn: "m1"), entry(.theme, zh: "太甜", turn: "t1"),
            .init(nameEn: "Pick between A and B", type: .vote, turnID: "m2", point: "", choice: "B", count: 5),
            .init(nameEn: "Pick between A and B", type: .vote, turnID: "m2", point: "", choice: "A", count: 1),
        ], names: nil), sources: [summary, tally, reply])
        XCTAssertEqual(book.cards.map(\.type), [.vote], "the summary is never a quote; one reply is not a code")
        let vote = try XCTUnwrap(book.cards.first)
        XCTAssertEqual(vote.votes?.map(\.choice), ["B", "A"])
        XCTAssertEqual(vote.votes?.map(\.count), [5, 1])
        XCTAssertEqual(vote.votes?.first?.source, "moderator_tally")
        XCTAssertTrue(vote.entries.isEmpty)
        let topic = try XCTUnwrap(book.topicMap().sections.first?.topics.first)
        XCTAssertEqual(book.topicMap().sections.first?.group, .votes)
        XCTAssertEqual(topic.tallies, [.init(choice: "B", count: 5), .init(choice: "A", count: 1)])
        XCTAssertEqual(book.scoped(to: "s1").cards.count, 1, "a vote card with no quote still reaches the session file")
        book.sessions = [.init(id: "s1", group: "G1", startedAt: Date(timeIntervalSince1970: 0), folder: "fixture")]
        XCTAssertTrue(ResearchCodebookStore.markdown(book).contains("- B: 5 [moderator_tally, 00:11:00]"))
    }

    func testAVoteNeverFilesTheModeratorsTallyIntoAnotherCode() throws {
        var book = ResearchCodebook()
        let sources = [quote("t1", 1, "太甜了。"), quote("t2", 2, "确实太甜。"),
                       quote("m1", 3, "觉得太甜的举手，一二三，三位。", moderator: true)]
        book.apply(.init(entries: [entry(.theme, zh: "太甜", turn: "t1"), entry(.theme, zh: "太甜", turn: "t2")], names: nil), sources: sources)
        let known = ResearchCodebookController.known(book, sessionID: "s1")
        let themeCode = try XCTUnwrap(known.codes.first?.id)
        book.apply(.init(entries: [
            .init(code: themeCode, type: .vote, turnID: "m1", point: "Hands up.", choice: "太甜", count: 3),
            .init(nameZh: "太甜", type: .vote, turnID: "m1", point: "Hands up.", choice: "太甜", count: 3),
            entry(.theme, code: themeCode, turn: "m1"),
        ], names: nil), sources: sources, codes: known.ids)
        XCTAssertEqual(book.cards.map(\.type), [.theme], "a vote never lands on a theme, by code id or by spelling")
        XCTAssertEqual(book.cards[0].entries.map(\.evidence.turnID), ["t1", "t2"], "the moderator's words are never a quote")

        // Same pass, same name, two types: whichever is filed first, the other never joins it.
        for order in [[0, 1, 2], [2, 0, 1]] {
            var fresh = ResearchCodebook()
            let items: [ResearchProposal.Item] = [
                entry(.theme, zh: "选口味", turn: "t1"), entry(.theme, zh: "选口味", turn: "t2"),
                .init(nameZh: "选口味", type: .vote, turnID: "m1", point: "", choice: "A", count: 3),
            ]
            fresh.apply(.init(entries: order.map { items[$0] }, names: nil), sources: sources)
            XCTAssertFalse(fresh.cards.flatMap(\.entries).contains { $0.evidence.speaker.moderator }, "order \(order)")
        }
    }

    func testATensionOrHypothesisNamedLikeAThemeIsNotFiledIntoIt() {
        var book = ResearchCodebook()
        let sources = [quote("t1", 1, "早上要快。"), quote("t2", 2, "快最重要。"), quote("t3", 30, "我喜欢慢慢喝。")]
        book.apply(.init(entries: [entry(.theme, zh: "要快", turn: "t1"), entry(.theme, zh: "要快", turn: "t2")], names: nil), sources: sources)
        book.apply(.init(entries: [entry(.tension, zh: "要快", turn: "t3", counter: "t1"), entry(.hypothesis, zh: "要快", turn: "t3")],
                         names: nil), sources: sources)
        XCTAssertEqual(book.cards.map(\.type), [.theme])
        XCTAssertEqual(book.cards[0].entries.map(\.evidence.turnID), ["t1", "t2"])
        XCTAssertNil(book.cards[0].entries.first { $0.counter != nil }, "the theme keeps no counter quote")
    }

    func testASchemaOneBookTakesAPassWithoutHidingQuotesInOldPeopleCards() throws {
        var book = ResearchCodebook()
        book.cards = [ResearchCard(id: UUID(), name: "Lumo", aliases: ["露慕"], type: .org, origin: .emerged, pinned: false, entries: []),
                      ResearchCard(id: UUID(), name: "小禾", aliases: [], type: .person, origin: .emerged, pinned: false, entries: [])]
        let sources = [quote("t1", 1, "露慕的盒子很好看。"), quote("t2", 2, "小禾这个名字挺可爱。"), quote("t3", 3, "小禾听着很亲切。")]
        book.apply(.init(entries: [entry(.brand, zh: "露慕", en: "Lumo", turn: "t1"),
                                   entry(.theme, zh: "小禾", turn: "t2"), entry(.theme, zh: "小禾", turn: "t3")], names: nil), sources: sources)
        XCTAssertTrue(book.cards[0].entries.isEmpty && book.cards[1].entries.isEmpty, "old people and org cards take no quotes")
        let brand = try XCTUnwrap(book.cards.first { $0.type == .brand })
        XCTAssertEqual(brand.entries.map(\.evidence.turnID), ["t1"])
        XCTAssertEqual(book.cards.first { $0.type == .theme }?.quoteCount, 2)
        let shown = book.topicMap().sections.flatMap(\.topics).map(\.name)
        XCTAssertEqual(Set(shown), ["露慕", "小禾"], "every filed quote is on a card the tab and rail show")
        XCTAssertEqual(ResearchCodebookController.known(book, sessionID: "s1").codes.count, 2)

        book.seed("Lumo")
        XCTAssertFalse(book.cards[0].seeded, "a seed never marks an old org card")
        XCTAssertEqual(book.cards.first { $0.type == .brand }?.seeded, true, "it marks the brand code with that spelling")
    }

    func testTheGroupFilterShowsOnlyThatGroupsTallies() {
        let sessions = [ResearchCodebook.Session(id: "a", group: "G1", startedAt: Date(timeIntervalSince1970: 0), folder: "a"),
                        ResearchCodebook.Session(id: "b", group: "G2", startedAt: Date(timeIntervalSince1970: 1), folder: "b")]
        var card = ResearchCard(id: UUID(), name: "Pick", aliases: [], type: .vote, origin: .emerged, pinned: false, entries: [])
        card.votes = [.init(sessionID: "a", choice: "B", count: 5, source: "moderator_tally", turnID: "m1", offsetMs: 0),
                      .init(sessionID: "b", choice: "B", count: 3, source: "moderator_tally", turnID: "m2", offsetMs: 0),
                      .init(sessionID: "b", choice: "A", count: 1, source: "moderator_tally", turnID: "m2", offsetMs: 0)]
        XCTAssertEqual(ResearchCodebook.votes(card, group: "G1", sessions: sessions).map(\.count), [5])
        XCTAssertEqual(ResearchCodebook.votes(card, group: "G2", sessions: sessions).map(\.count), [3, 1])
        XCTAssertEqual(ResearchCodebook.votes(card, group: nil, sessions: sessions).count, 3)
    }

    func testATensionCitesBothSidesEvenAcrossPasses() throws {
        var book = ResearchCodebook()
        let early = quote("t1", 8, "我买东西从来不看包装。"), early2 = quote("t2", 8.5, "包装无所谓，看成分。")
        book.apply(.init(entries: [entry(.theme, zh: "不看包装", turn: "t1"), entry(.theme, zh: "不看包装", turn: "t2")], names: nil),
                   sources: [early, early2])
        let late = quote("t9", 34, "其实我就是因为瓶子好看才买的。")
        book.apply(.init(entries: [
            entry(.tension, zh: "说不看包装却因瓶子买", en: "Says packaging does not matter, bought it for the bottle",
                  turn: "t9", counter: "t1", quote: "因为瓶子好看才买", valence: .mixed),
            entry(.tension, zh: "没有另一边", turn: "t9"),
        ], names: nil), sources: [late])
        let tension = try XCTUnwrap(book.cards.first { $0.type == .tension })
        XCTAssertEqual(book.cards.filter { $0.type == .tension }.count, 1, "a tension needs a second turn")
        XCTAssertEqual(tension.entries.first?.counter?.turnID, "t1", "the earlier side comes from an earlier pass")
        XCTAssertEqual(tension.quoteCount, 2)
        let topic = try XCTUnwrap(book.topicMap().sections.first { $0.group == .tensions }?.topics.first)
        XCTAssertEqual(topic.sides.map(\.offsetMs), [480_000, 2_040_000])
        XCTAssertEqual(topic.sides.map(\.words), ["我买东西从来不看包装。", "因为瓶子好看才买"])
    }

    func testAboutFortyCodesASessionAndVotesStillLand() {
        var book = ResearchCodebook()
        let sources = (0 ..< 2).map { quote("t\($0)", Double($0), "回答\($0)") }
        book.cards = (0 ..< ResearchCodebook.sessionCodeCap).map { n in
            ResearchCard(id: UUID(), name: "主题\(n)", aliases: [], type: .theme, origin: .emerged, pinned: false,
                         entries: [.init(point: "A point.", evidence: quote("old\(n)", 1, "旧的"), valence: .neutral, inferredName: nil)])
        }
        book.apply(.init(entries: [
            entry(.theme, zh: "新主题", turn: "t0"), entry(.theme, zh: "新主题", turn: "t1"),
            .init(nameEn: "Pick", type: .vote, turnID: "t0", point: "", choice: "A", count: 3),
        ], names: nil), sources: sources)
        XCTAssertFalse(book.cards.contains { $0.name == "新主题" })
        XCTAssertTrue(book.cards.contains { $0.type == .vote })
    }

    func testAModelReplyDecodesLeniently() throws {
        let json = """
        {"entries":[
          {"code":null,"name_zh":"图个省事","name_en":"Effortless","type":"emic term","turnID":"t1","quote":"图个省事","valence":"great","strength":"PROMPTED","asrDoubt":"yes"},
          {"name":"Old shape","type":"concept","turnID":"t2","point":"Older reply shape."},
          {"type":"vote","turnID":"m1","choice":"B","count":"5 hands"},
          {"name_en":"No turn","type":"theme"},
          {"name_en":"Bad type","type":42,"turnID":"t3","point":"Kept, untyped."}
        ],"names":{"broken":true}}
        """
        let proposal = try ResearchCodebookController.decode(ResearchProposal.self, from: "```json\n" + json + "\n```")
        XCTAssertEqual(proposal.entries.count, 4, "only the entry with no turn is dropped")
        XCTAssertEqual(proposal.entries[0].type, .emicTerm)
        XCTAssertEqual(proposal.entries[0].valence, .neutral, "a bad field drops the field")
        XCTAssertEqual(proposal.entries[0].strength, .prompted)
        XCTAssertEqual(proposal.entries[1].type, .theme)
        XCTAssertEqual(proposal.entries[1].nameEn, "Old shape")
        XCTAssertEqual(proposal.entries[2].count, 5)
        XCTAssertNil(proposal.entries[3].type)
        XCTAssertNil(proposal.names)
        let synthesis = try ResearchCodebookController.decode(ResearchSynthesis.self, from: """
        {"merges":[{"from":"c2","into":"c1"},{"from":"c3"}],"tensions":[{"turnID":"t1","counterTurnID":"t9","name_zh":"矛盾"}],
         "hypotheses":[{"code":"c4","for":"t1","against":["t2",""]}],"clientQuestions":[{"code":"c5","status":"partially answered","turnIDs":["t1"]}]}
        """)
        XCTAssertEqual(synthesis.merges.count, 1)
        XCTAssertEqual(synthesis.tensions.first?.nameZh, "矛盾")
        XCTAssertEqual(synthesis.hypotheses.first?.support, ["t1"])
        XCTAssertEqual(synthesis.hypotheses.first?.against, ["t2"])
        XCTAssertEqual(synthesis.clientQuestions.first?.status, .partly)
    }

    // MARK: - Synthesis

    func testSynthesisMergesFindsTensionsCountsHypothesesAndTracksClientQuestions() throws {
        var book = ResearchCodebook()
        book.seed("Morning drinks are about speed", type: .hypothesis)
        book.seed("Would they switch from cow's milk?", type: .clientQuestion)
        book.seed("清悦", type: .brand)
        book.seed("晴越", type: .brand)
        let sources = [quote("t1", 5, "早上快最重要。"), quote("t2", 5.5, "快就行，味道其次。"), quote("t3", 30, "我愿意慢慢喝，享受一下。"),
                       quote("t4", 31, "我已经不喝牛奶了。"), quote("t5", 32, "清悦好喝。"), quote("t6", 33, "晴越也好喝。")]
        book.apply(.init(entries: [
            entry(.theme, zh: "要快", en: "Speed first", turn: "t1"), entry(.theme, zh: "要快", turn: "t2"),
            entry(.theme, zh: "图快", en: "Quick", turn: "t1"), entry(.theme, zh: "图快", turn: "t3"),
            entry(.theme, zh: "不喝牛奶", turn: "t4"), entry(.theme, zh: "不喝牛奶", turn: "t2"),
            entry(.brand, zh: "清悦", turn: "t5"), entry(.brand, zh: "晴越", turn: "t6"),
        ], names: nil), sources: sources)
        let known = ResearchCodebookController.known(book, sessionID: "s1")
        func code(_ name: String) throws -> String {
            let id = try XCTUnwrap(book.cards.first { $0.name == name }?.id)
            return try XCTUnwrap(known.ids.first { $0.value == id }?.key)
        }
        let synthesis = try ResearchSynthesis(
            merges: [.init(from: code("图快"), into: code("要快")), .init(from: code("清悦"), into: code("晴越"))],
            tensions: [.init(nameZh: "要快还是享受", nameEn: "Speed or savouring", turnID: "t3", counterTurnID: "t1", point: nil),
                       .init(nameZh: "同一分钟", nameEn: nil, turnID: "t1", counterTurnID: "t2", point: nil)],
            hypotheses: [.init(code: code("Morning drinks are about speed"), nameZh: nil, nameEn: nil, support: ["t1", "t2"], against: ["t3", "nope"], point: nil)],
            clientQuestions: [.init(code: code("Would they switch from cow's milk?"), status: .answered, turnIDs: ["t4"])]
        )
        book.apply(synthesis, sessionID: "s1", codes: known.ids)
        XCTAssertNil(book.cards.first { $0.name == "图快" }, "a synonym merges")
        XCTAssertEqual(book.cards.first { $0.name == "要快" }?.quoteCount, 3)
        XCTAssertNotNil(book.cards.first { $0.name == "清悦" }, "two brands never merge")
        let tensions = book.cards.filter { $0.type == .tension }
        XCTAssertEqual(tensions.map(\.name), ["要快还是享受"], "a tension needs two different minutes")
        XCTAssertEqual(tensions.first?.gloss, "Speed or savouring")
        XCTAssertEqual(tensions.first?.entries.first?.counter?.turnID, "t1")
        let hypothesis = try XCTUnwrap(book.cards.first { $0.type == .hypothesis })
        XCTAssertEqual(hypothesis.support.for, 2)
        XCTAssertEqual(hypothesis.support.against, 1)
        let question = try XCTUnwrap(book.cards.first { $0.type == .clientQuestion })
        XCTAssertEqual(question.questionStatus, .answered)
        XCTAssertEqual(question.entries.map(\.evidence.turnID), ["t4"])
        let topics = book.topicMap()
        XCTAssertEqual(topics.sections.map(\.group), [.tensions, .hypotheses, .questions, .brands, .themes])
        let row = try XCTUnwrap(topics.sections.first { $0.group == .hypotheses }?.topics.first)
        XCTAssertEqual(row.support, 2)
        XCTAssertEqual(row.against, 1)
    }

    func testSynthesisRunsEveryTenMinutesOnlyWithNewQuotes() throws {
        typealias C = ResearchCodebookController
        XCTAssertFalse(C.synthesisDue(nowMs: 540_000, lastMs: nil, quotes: 20, quotesAtLast: 0, codes: 8))
        XCTAssertTrue(C.synthesisDue(nowMs: 600_000, lastMs: nil, quotes: 20, quotesAtLast: 0, codes: 8))
        XCTAssertFalse(C.synthesisDue(nowMs: 1_100_000, lastMs: 600_000, quotes: 25, quotesAtLast: 20, codes: 8))
        XCTAssertTrue(C.synthesisDue(nowMs: 1_200_000, lastMs: 600_000, quotes: 25, quotesAtLast: 20, codes: 8))
        XCTAssertFalse(C.synthesisDue(nowMs: 1_200_000, lastMs: 600_000, quotes: 20, quotesAtLast: 20, codes: 8), "nothing new")
        XCTAssertFalse(C.synthesisDue(nowMs: 1_200_000, lastMs: nil, quotes: 5, quotesAtLast: 0, codes: 3), "too few codes")

        var book = ResearchCodebook()
        let sources = [quote("t1", 5, "早上快最重要。"), quote("t2", 6, "快就行。"), quote("t3", 30, "我愿意慢慢喝，享受一下这个过程，不赶时间，这样一天的心情都会比较好一点。")]
        book.apply(.init(entries: [entry(.theme, zh: "要快", turn: "t1"), entry(.theme, zh: "要快", turn: "t2"),
                                   entry(.theme, zh: "要快", turn: "t3")], names: nil), sources: sources)
        let input = try XCTUnwrap(C.synthesisInput(book, sessionID: "s1", brief: "Objective: test.", nowMs: 1_800_000))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: input.json) as? [String: Any])
        XCTAssertEqual(json["minute"] as? Int, 30)
        let codes = try XCTUnwrap(json["codes"] as? [[String: Any]])
        let best = try XCTUnwrap(codes.first?["best"] as? [[String: Any]])
        XCTAssertEqual(best.map { $0["turn"] as? String }, ["t1", "t3"], "the earliest and the latest quote")
        XCTAssertLessThanOrEqual((best.last?["original"] as? String)?.count ?? 0, 80)
        XCTAssertEqual(codes.first?["quotes"] as? Int, 3)
    }

    // MARK: - Brief and seeds

    func testSeedLinesBuildTheBriefAndKnownCodes() throws {
        var book = ResearchCodebook()
        for line in ["# Seeds", "client | 露慕（Lumo）", "objective | Learn why people pick an oat drink for breakfast",
                     "client_question | Would they pay more for less sugar?", "person | 小禾", "org | Corner Shop",
                     "hypothesis | Speed beats taste in the morning", "- barrier | 怕胀气", "Side pocket"]
        {
            ResearchCodebookStore.seed(line, into: &book)
        }
        XCTAssertEqual(book.objective, "Learn why people pick an oat drink for breakfast")
        XCTAssertFalse(book.cards.contains { $0.name == "小禾" }, "a typed name never becomes a code")
        XCTAssertEqual(book.cards.first { $0.name == "Corner Shop" }?.type, .brand)
        XCTAssertEqual(book.cards.first { $0.name == "Side pocket" }?.type, .theme)
        XCTAssertEqual(book.cards.first { $0.type == .clientQuestion }?.questionStatus, .open)
        let client = try XCTUnwrap(book.cards.first { $0.clientBrand == true })
        XCTAssertTrue(client.pinned)
        let guide = try GuideDocument.parse(JSONSerialization.data(withJSONObject: ["title": "Invented", "sections": [
            ["id": "S1", "title": "Warm-up", "minutes": 10, "questions": [["qid": "S1Q1", "en": "Mornings?", "zh": "早上？", "probes": []]]],
            ["id": "S2", "title": "Oat drinks", "minutes": 20, "questions": [["qid": "S2Q1", "en": "Why oat?", "zh": "为什么燕麦？", "probes": []]]],
        ]]))
        let brief = ResearchCodebook.brief(book: book, guide: guide, stimulusCodes: ["A1", "B1"])
        XCTAssertLessThanOrEqual(brief.count, 600)
        for part in ["Objective: Learn why", "Client brand: 露慕（Lumo）", "Stimulus: A1, B1", "Guide: S1 Warm-up; S2 Oat drinks",
                     "Client questions: Would they pay more", "Hypotheses: Speed beats taste"]
        {
            XCTAssertTrue(brief.contains(part), "\(part) missing from: \(brief)")
        }
        let known = ResearchCodebookController.known(book, sessionID: "s1").codes
        XCTAssertEqual(known.first?.id, "c1")
        XCTAssertEqual(known.first?.nameZh, "露慕（Lumo）")
        XCTAssertEqual(Set(known.map(\.type)), ["brand", "client_question", "hypothesis", "barrier", "theme"])
    }

    // MARK: - Prompts

    func testTheShippedPromptsCarryTheMeaningsContract() {
        let pass = PromptID.researchCodebook.defaultText
        for token in ["JSON", "turnID", "counterTurnID", "name_zh", "emic_term", "client_question", "asrDoubt",
                      "At most three new non-brand codes", "Never merge two brands", "Count quotes, never people", "vote"]
        {
            XCTAssertTrue(pass.contains(token), token)
        }
        XCTAssertFalse(pass.contains("person|"), "no person type")
        XCTAssertFalse(pass.contains("Write points in English."))
        let synthesis = PromptID.researchCodebookSynthesis.defaultText
        for token in ["merges", "tensions", "hypotheses", "clientQuestions", "different minutes", "Never merge two brands"] {
            XCTAssertTrue(synthesis.contains(token), token)
        }
    }
}
