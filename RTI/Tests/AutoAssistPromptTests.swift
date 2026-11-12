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

    func testLanguageRuleReplacesEnglishOnly() throws {
        XCTAssertTrue(PromptID.autoAssistCards.defaultText.contains("Write in English."), "the shipped contract text must not change")
        for callType in [CallType.client, .research] {
            let prompt = try XCTUnwrap(build(callType))
            XCTAssertFalse(prompt.contains("Write in English."))
            XCTAssertEqual(prompt.components(separatedBy: "Language: ").count, 2, "one language rule per prompt")
            XCTAssertTrue(prompt.contains(AutoAssistPrompt.languageRule))
            XCTAssertFalse(prompt.contains(PromptID.recapLanguageRule.defaultText), "Recap's rule is not Auto's")
            XCTAssertTrue(prompt.contains("JSON"))
        }
    }

    func testLanguageRuleIsKeyedOnTheMeetingAndLiftsTheCapForMandarin() {
        let rule = AutoAssistPrompt.languageRule
        XCTAssertTrue(rule.contains("judge the meeting's language from the conversation itself"))
        XCTAssertTrue(rule.contains("In an English meeting, write it in English only."))
        XCTAssertTrue(rule.contains("speakable Mandarin line and then its tone-marked pinyin"))
        XCTAssertTrue(rule.contains("The 25-word limit on \"text\" counts the English line only."))
        XCTAssertTrue(rule.contains("every \"why\" in English, with no pinyin"))
        XCTAssertFalse(rule.contains("explicit answer language"), "a background pass has no user request")
        XCTAssertFalse(rule.contains("\\"), "line continuations must not leak into the text")
    }

    func testFramingsCarryNoSecondLanguageRule() {
        for id in [PromptID.autoAssistClient, .autoAssistResearch] {
            XCTAssertFalse(id.defaultText.contains("Language:"), "\(id) must leave language to the one Auto rule")
        }
    }

    func testEditedContractWithoutTheSentenceStillGetsTheRuleOnce() throws {
        let resolve: PromptComposer.Resolver = { $0 == .autoAssistCards ? "Output ONLY JSON." : $0.defaultText }
        let prompt = try XCTUnwrap(build(.client, resolve: resolve))
        XCTAssertTrue(prompt.hasPrefix("Output ONLY JSON.\n\n" + AutoAssistPrompt.languageRule))
        XCTAssertEqual(prompt.components(separatedBy: AutoAssistPrompt.languageRule).count, 2)
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
        XCTAssertTrue(prompt.contains("set \"sourceId\" on the card"))
        XCTAssertTrue(prompt.contains("Already-surfaced (do NOT repeat):\n(none yet)"))
        XCTAssertFalse(prompt.contains("Guide gaps"))
    }

    func testFramingPromptsCarryTheirRules() {
        let client = PromptID.autoAssistClient.defaultText
        XCTAssertTrue(client.contains("steers the call toward the goal in the brief"))
        XCTAssertTrue(client.contains("proactive idea"))
        XCTAssertTrue(client.contains("Silence beats noise"))
        let research = PromptID.autoAssistResearch.defaultText
        XCTAssertTrue(research.contains("gaps list"))
        XCTAssertTrue(research.contains("Never write a leading question"))
        XCTAssertTrue(research.contains("exact original words"))
        XCTAssertTrue(research.contains("Do not name or count people"))
        XCTAssertTrue(research.contains("Silence beats noise"))
    }
}
