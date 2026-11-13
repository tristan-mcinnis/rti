import RTICore
import XCTest

/// Pins the call-aware Auto prompt: which call types run, what each one sees,
/// the one Auto language rule, typed notes, and the two labelled transcript windows.
final class AutoAssistPromptTests: XCTestCase {
    private let gaps = [
        GuideGap(qid: "Q3", title: "How do you choose a brand?", titleZH: "你怎么选品牌？", state: .skipped),
        GuideGap(qid: "Q2", title: "Last purchase", titleZH: nil, state: .thin(quotes: 1)),
    ]

    private func build(
        _ callType: CallType,
        brief: String? = "BRIEF: lock the launch date",
        recentContext: String? = "[00:01, Them] earlier words",
        newWindow: String = "[00:04, Them] new words",
        resolve: PromptComposer.Resolver? = nil
    ) -> String? {
        AutoAssistPrompt.build(
            callType: callType,
            brief: brief,
            projectContext: "PROJECT: fixture study",
            gaps: gaps,
            currentQuestion: "Q4 What did you buy last?",
            prior: ["- [ASK] earlier card"],
            vault: nil,
            recentContext: recentContext,
            newWindow: newWindow,
            resolve: resolve ?? PromptComposer.defaultResolver
        )
    }

    func testResearchIncludesGapsAndCurrentQuestionButNotTheBrief() throws {
        let prompt = try XCTUnwrap(build(.research))
        XCTAssertTrue(prompt.contains(PromptID.autoAssistResearch.defaultText))
        XCTAssertTrue(prompt.contains("- [Q3] How do you choose a brand? / 你怎么选品牌？ (Skipped)"))
        XCTAssertTrue(prompt.contains("- [Q2] Last purchase (Thin: 1 quote)"))
        XCTAssertTrue(prompt.contains("Current guide question:\nQ4 What did you buy last?"))
        XCTAssertFalse(prompt.contains("BRIEF: lock the launch date"))
        XCTAssertFalse(prompt.contains(PromptID.autoAssistClient.defaultText))
    }

    func testClientIncludesTheBriefButNoGuide() throws {
        let prompt = try XCTUnwrap(build(.client))
        XCTAssertTrue(prompt.contains(PromptID.autoAssistClient.defaultText))
        XCTAssertTrue(prompt.contains("Pre-meeting brief (the goal of this call; steer toward it):\n---\nBRIEF: lock the launch date\n---"))
        XCTAssertFalse(prompt.contains("[Q3]"))
        XCTAssertFalse(prompt.contains("Current guide question"))
        XCTAssertTrue(prompt.contains("PROJECT: fixture study"))
    }

    func testInternalAndPersonalProduceNoPrompt() {
        XCTAssertNil(build(.internal))
        XCTAssertNil(build(.personal))
        XCTAssertNil(AutoAssistPrompt.framing(for: .internal))
        XCTAssertNil(AutoAssistPrompt.framing(for: .personal))
        XCTAssertEqual(AutoAssistPrompt.framing(for: .client), .autoAssistClient)
        XCTAssertEqual(AutoAssistPrompt.framing(for: .research), .autoAssistResearch)
    }

    func testEmptyNewWindowSkipsThePass() {
        XCTAssertNil(build(.client, newWindow: "  \n "))
    }

    func testLanguageRuleIsItsOwnSectionAfterTheFraming() throws {
        XCTAssertFalse(PromptID.autoAssistCards.defaultText.contains("Write in English."), "the contract leaves language to the rule")
        for callType in [CallType.client, .research] {
            let prompt = try XCTUnwrap(build(callType))
            XCTAssertFalse(prompt.contains("Write in English."))
            XCTAssertEqual(prompt.components(separatedBy: "Language: ").count, 2, "one language rule per prompt")
            let framing = try XCTUnwrap(prompt.range(of: try XCTUnwrap(AutoAssistPrompt.framing(for: callType)).defaultText))
            let rule = try XCTUnwrap(prompt.range(of: AutoAssistPrompt.languageRule))
            XCTAssertLessThan(framing.upperBound, rule.lowerBound)
            XCTAssertFalse(prompt.contains(PromptID.recapLanguageRule.defaultText), "Recap's rule is not Auto's")
            XCTAssertTrue(prompt.contains("JSON"))
        }
    }

    func testLanguageRuleAsksForASeparateMandarinFieldAndNoPinyin() {
        let rule = AutoAssistPrompt.languageRule
        XCTAssertTrue(rule.contains("judge the meeting's language from the conversation itself"))
        XCTAssertTrue(rule.contains("Always write \"text_en\" in English."))
        XCTAssertTrue(rule.contains("also write \"text_zh\", a natural, speakable Mandarin line"))
        XCTAssertTrue(rule.contains("No pinyin anywhere"))
        XCTAssertTrue(rule.contains("every \"why\" in English"))
        XCTAssertFalse(rule.contains("explicit answer language"), "a background pass has no user request")
        XCTAssertFalse(rule.contains("\\"), "line continuations must not leak into the text")
        let contract = PromptID.autoAssistCards.defaultText
        for field in ["\"text_en\"", "\"text_zh\"", "\"why\"", "\"source\""] {
            XCTAssertTrue(contract.contains(field), field)
        }
        XCTAssertTrue(PromptID.autoAssistCards.requiredTokens.contains("text_zh"))
    }

    func testMandarinLineGoesJustBeforeTheNewWindowOnlyWhenAsked() throws {
        let plain = try XCTUnwrap(build(.research))
        XCTAssertFalse(plain.contains(AutoAssistPrompt.mandarinLine))
        let mandarin = try XCTUnwrap(AutoAssistPrompt.build(
            callType: .research, brief: nil, projectContext: nil, gaps: [], currentQuestion: nil,
            prior: [], vault: nil, recentContext: nil, mandarin: true, newWindow: "[00:04, Them] 我觉得还行。"
        ))
        XCTAssertTrue(mandarin.contains(AutoAssistPrompt.mandarinLine + "\n\nNew conversation since the last pass"))
    }

    func testStablePartsLeadSoConsecutivePassesShareAPrefix() throws {
        func pass(prior: [String], window: String, signals: [String]) throws -> String {
            try XCTUnwrap(AutoAssistPrompt.build(
                callType: .research, brief: nil, projectContext: "PROJECT: fixture study", gaps: gaps,
                currentQuestion: "S2Q1 / How do you pick a drink?", sectionBudgets: ["S1 Warm-up: 10 min", "S2 Habits: 15 min"],
                prior: prior, codes: ["- Tension: 健康 vs 好喝 (2 quotes)"], signals: signals, vault: nil,
                recentContext: "[00:01, Them] earlier", newWindow: window
            ))
        }
        let first = try pass(prior: [], window: "[00:04, Them] 我早上喝燕麦奶。", signals: [])
        let second = try pass(prior: ["- [ask] 有没有人不一样的看法？"], window: "[02:34, Them] 我觉得太甜了。",
                              signals: ["No Them speech for 3 min (since 00:10): the other side's audio may have dropped."])
        let stable = try XCTUnwrap(first.range(of: "Already-surfaced"))
        let prefix = String(first[..<stable.lowerBound])
        XCTAssertTrue(second.hasPrefix(prefix), "everything before the surfaced cards is the same from pass to pass")
        XCTAssertTrue(prefix.contains("Guide section budgets:\n- S1 Warm-up: 10 min\n- S2 Habits: 15 min"))
        XCTAssertTrue(prefix.contains("Current guide question:\nS2Q1"))
        XCTAssertTrue(prefix.contains("PROJECT: fixture study"))
        let order = ["Already-surfaced", "Codebook tensions and hypotheses", "Signals (facts from the app)",
                     "Guide gaps", "Earlier conversation", "New conversation"]
        let positions = try order.map { try XCTUnwrap(second.range(of: $0), $0).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(second.contains("- Tension: 健康 vs 好喝 (2 quotes)"))
    }

    func testOlderSurfacedCardsGoAsOneTopicLine() throws {
        let prompt = try XCTUnwrap(AutoAssistPrompt.build(
            callType: .client, brief: nil, projectContext: nil, gaps: [], currentQuestion: nil,
            prior: ["- [ask] newest"], priorTopics: "who signs off; renewal date", vault: nil,
            recentContext: nil, newWindow: "words"
        ))
        XCTAssertTrue(prompt.contains("Already-surfaced (do NOT repeat, even in other words):\n- [ask] newest\nEarlier cards were about: who signs off; renewal date"))
    }

    func testClientGetsNoCodesSignalsOrBudgets() throws {
        let prompt = try XCTUnwrap(AutoAssistPrompt.build(
            callType: .client, brief: nil, projectContext: nil, gaps: [], currentQuestion: nil,
            sectionBudgets: ["S1 Warm-up: 10 min"], prior: [], codes: ["- Tension: x"], signals: ["silence"],
            vault: nil, recentContext: nil, newWindow: "words"
        ))
        XCTAssertFalse(prompt.contains("Guide section budgets"))
        XCTAssertFalse(prompt.contains("Codebook tensions"))
        XCTAssertFalse(prompt.contains("Signals"))
    }

    func testFramingsCarryNoSecondLanguageRule() {
        for id in [PromptID.autoAssistClient, .autoAssistResearch] {
            XCTAssertFalse(id.defaultText.contains("Language:"), "\(id) must leave language to the one Auto rule")
        }
    }

    func testAnOlderEditedContractLosesItsEnglishOnlySentenceAndGetsTheRuleOnce() throws {
        let resolve: PromptComposer.Resolver = { $0 == .autoAssistCards ? "Output ONLY JSON. Write in English." : $0.defaultText }
        let prompt = try XCTUnwrap(build(.client, resolve: resolve))
        XCTAssertTrue(prompt.hasPrefix("Output ONLY JSON.\n\n" + PromptID.autoAssistClient.defaultText + "\n\n" + AutoAssistPrompt.languageRule))
        XCTAssertEqual(prompt.components(separatedBy: AutoAssistPrompt.languageRule).count, 2)
        XCTAssertFalse(prompt.contains("Write in English."))
    }

    func testAnEditedRecapRuleDoesNotReachAuto() throws {
        let resolve: PromptComposer.Resolver = { $0 == .recapLanguageRule ? "RECAP_ONLY_RULE" : $0.defaultText }
        let prompt = try XCTUnwrap(build(.research, resolve: resolve))
        XCTAssertFalse(prompt.contains("RECAP_ONLY_RULE"))
    }

    func testUserNotesGetTheirOwnSectionBeforeTheTranscript() throws {
        let prompt = try XCTUnwrap(AutoAssistPrompt.build(
            callType: .client, brief: nil, projectContext: nil, gaps: [], currentQuestion: nil,
            prior: [], userNotes: ["Budget is fixed", "  "], vault: nil,
            recentContext: "[00:01, Them] earlier", newWindow: "[00:04, Them] new"
        ))
        let notes = try XCTUnwrap(prompt.range(of: "Notes the user typed during this call (authoritative; trust them over the transcript):\n- Budget is fixed"))
        let context = try XCTUnwrap(prompt.range(of: "Earlier conversation (context only"))
        XCTAssertLessThan(notes.lowerBound, context.lowerBound)
        XCTAssertFalse(prompt.contains("- \n"), "a blank note adds no bullet")
    }

    func testOverridesFlowThroughTheResolver() throws {
        let resolve: PromptComposer.Resolver = { $0 == .autoAssistResearch ? "EDITED_RESEARCH" : $0.defaultText }
        let prompt = try XCTUnwrap(build(.research, resolve: resolve))
        XCTAssertTrue(prompt.contains("EDITED_RESEARCH"))
        XCTAssertFalse(prompt.contains(PromptID.autoAssistResearch.defaultText))
    }

    func testContextAndNewWindowsAreBothLabelledInOrder() throws {
        let prompt = try XCTUnwrap(build(.client))
        let context = try XCTUnwrap(prompt.range(of: "Earlier conversation (context only; do not make cards about it):\n[00:01, Them] earlier words"))
        let fresh = try XCTUnwrap(prompt.range(of: "New conversation since the last pass (act on this):\n[00:04, Them] new words"))
        XCTAssertLessThan(context.lowerBound, fresh.lowerBound)
        XCTAssertTrue(prompt.hasSuffix("[00:04, Them] new words"))
    }

    func testFirstPassHasNoContextWindow() throws {
        let prompt = try XCTUnwrap(build(.client, recentContext: nil))
        XCTAssertFalse(prompt.contains("context only"))
        XCTAssertTrue(prompt.contains("(act on this)"))
    }

    func testVaultMaterialCarriesTheCitationInstruction() throws {
        let prompt = try XCTUnwrap(AutoAssistPrompt.build(
            callType: .research, brief: nil, projectContext: nil, gaps: [], currentQuestion: nil,
            prior: [], vault: "[S1] fixture.md", recentContext: nil, newWindow: "words"
        ))
        XCTAssertTrue(prompt.contains("[S1] fixture.md"))
        XCTAssertTrue(prompt.contains("set \"source\" on the card"))
        XCTAssertTrue(prompt.contains("A RECALL with any other value, or none, is dropped."))
        XCTAssertTrue(prompt.contains("Already-surfaced (do NOT repeat, even in other words):\n(none yet)"))
        XCTAssertFalse(prompt.contains("Guide gaps"))
    }

    func testFramingPromptsCarryTheirRules() {
        let client = PromptID.autoAssistClient.defaultText
        XCTAssertTrue(client.contains("steers the call toward the goal in the brief"))
        XCTAssertTrue(client.contains("proactive idea"))
        XCTAssertTrue(client.contains("Silence beats noise"))
        XCTAssertTrue(client.contains("presenting"), "P9: presenting or receiving")
        XCTAssertTrue(client.contains("never quiz a colleague"))
        XCTAssertTrue(client.contains("FLAG the consent scope (minors, images)"))
        XCTAssertTrue(client.contains("Never commit the user to sending recordings, raw data, participant photos or a deadline."))
        XCTAssertTrue(client.contains("Use only names that appear word for word"))
        let research = PromptID.autoAssistResearch.defaultText
        XCTAssertTrue(research.contains("gaps list"))
        XCTAssertTrue(research.contains("Never write a leading question"))
        XCTAssertTrue(research.contains("exact original words"))
        XCTAssertTrue(research.contains("Do not name or count people"))
        XCTAssertTrue(research.contains("Silence beats noise"))
        XCTAssertTrue(research.contains("Fit the probe to the moment") || research.contains("fit the probe to the moment"))
        XCTAssertTrue(research.contains("at most once every 10 minutes"))
        XCTAssertTrue(research.contains("FLAG only for"))
        XCTAssertTrue(research.contains("Never pair an ASK and a FLAG on the same quote."))
        XCTAssertTrue(research.contains("If no guide is supplied, never mention a guide."))
        XCTAssertTrue(research.contains("At most one card per pass, unless a contradiction appears."))
        XCTAssertFalse(research.contains("Can you walk me through…?\", \"What do you mean"), "the old template list is gone")
    }
}
