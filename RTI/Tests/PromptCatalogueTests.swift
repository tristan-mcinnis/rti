import RTICore
import XCTest

/// Pins the prompt catalogue's pure selection logic — the listener/speaker
/// switch, recap-depth splicing, and mode-shaped summary — that previously lived
/// interleaved with dispatch inside the @MainActor LLMController and could not be
/// reached by a test. Distinctive substrings double as drift guards: if a prompt
/// is silently altered, the matching assertion fails.
final class PromptCatalogueTests: XCTestCase {

    // MARK: - Recap depth

    func test_recap_variesOnlyInBulletClause_sharedLanguageRule() {
        let brief = PromptComposer.recap(.brief)
        let standard = PromptComposer.recap(.standard)
        let detailed = PromptComposer.recap(.detailed)

        XCTAssertTrue(brief.contains("1–2 short bullets"))
        XCTAssertTrue(standard.contains("3–5 short bullets"))
        XCTAssertTrue(detailed.contains("8–12 bullets grouped"))

        // Every depth starts with the same stem and carries the same language rule.
        for p in [brief, standard, detailed] {
            XCTAssertTrue(p.hasPrefix("Recap the conversation so far "))
            XCTAssertTrue(p.contains("Answer in English bullets only"))
        }
        XCTAssertNotEqual(brief, standard)
        XCTAssertNotEqual(standard, detailed)
    }

    func test_recapDepth_catalogue() {
        XCTAssertEqual(RecapDepth.allCases.map(\.rawValue), ["brief", "standard", "detailed"])
        let labels = RecapDepth.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, 3)         // distinct
        XCTAssertFalse(labels.contains(where: \.isEmpty))
    }

    // MARK: - Listener vs speaker framing

    func test_assist_switchesOnListenerState() {
        let speaker = PromptComposer.assist(listener: false)
        let listener = PromptComposer.assist(listener: true)
        XCTAssertTrue(speaker.contains("suggest what I should say or ask next"))
        XCTAssertTrue(listener.contains("**[TAG]**"))
        XCTAssertTrue(listener.contains("**Matters:**"))
        XCTAssertNotEqual(speaker, listener)
    }

    func test_followups_switchesOnListenerState() {
        let speaker = PromptComposer.followups(listener: false)
        let listener = PromptComposer.followups(listener: true)
        XCTAssertTrue(speaker.contains("List 3 thoughtful follow-up questions"))
        XCTAssertTrue(listener.contains("I'm a passive listener"))
        XCTAssertNotEqual(speaker, listener)
    }

    func test_sayNext_hasNoListenerVariant() {
        XCTAssertTrue(PromptID.sayNext.defaultText.contains("draft exactly one short reply"))
    }

    // MARK: - Listener research actions

    func test_listenerResearchPrompts() {
        XCTAssertTrue(PromptID.keyTensions.defaultText.contains("unprobed tension"))
        XCTAssertTrue(PromptID.probe.defaultText.contains("an echo"))
        XCTAssertTrue(PromptID.themes.defaultText.contains("raised after a moderator question"))
    }

    // MARK: - Auto framing

    func test_autoFramingPrompts() {
        XCTAssertEqual(PromptID.autoAssistClient.title, "Auto cards — client call")
        XCTAssertEqual(PromptID.autoAssistResearch.title, "Auto cards — research")
        XCTAssertTrue(PromptID.autoAssistClient.defaultText.hasPrefix("CALL TYPE: client call."))
        XCTAssertTrue(PromptID.autoAssistResearch.defaultText.hasPrefix("CALL TYPE: research session."))
    }

    // MARK: - System

    func test_systemPrompt_present() {
        XCTAssertTrue(PromptID.systemDefault.defaultText.contains("You are RTI, a real-time meeting assistant"))
        XCTAssertTrue(PromptID.systemDefault.defaultText.contains("## User notes"))
    }
}
