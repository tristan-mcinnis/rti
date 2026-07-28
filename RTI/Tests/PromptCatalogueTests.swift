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
        let brief = PromptCatalogue.recap(.brief)
        let standard = PromptCatalogue.recap(.standard)
        let detailed = PromptCatalogue.recap(.detailed)

        XCTAssertTrue(brief.contains("1–2 short bullets"))
        XCTAssertTrue(standard.contains("3–5 short bullets"))
        XCTAssertTrue(detailed.contains("8–12 bullets grouped"))

        // Every depth starts with the same stem and carries the same language rule.
        for p in [brief, standard, detailed] {
            XCTAssertTrue(p.hasPrefix("Recap the conversation so far "))
            XCTAssertTrue(p.contains("Reply in ENGLISH regardless of the conversation's language"))
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
        let speaker = PromptCatalogue.assist(listener: false)
        let listener = PromptCatalogue.assist(listener: true)
        XCTAssertTrue(speaker.contains("suggest what I should say or ask next"))
        XCTAssertTrue(listener.contains("**[TAG]**"))
        XCTAssertTrue(listener.contains("**Matters:**"))
        XCTAssertNotEqual(speaker, listener)
    }

    func test_followups_switchesOnListenerState() {
        let speaker = PromptCatalogue.followups(listener: false)
        let listener = PromptCatalogue.followups(listener: true)
        XCTAssertTrue(speaker.contains("List 3 thoughtful follow-up questions"))
        XCTAssertTrue(listener.contains("I'm a passive listener"))
        XCTAssertNotEqual(speaker, listener)
    }

    func test_sayNext_hasNoListenerVariant() {
        XCTAssertTrue(PromptCatalogue.sayNext.contains("draft exactly one short reply"))
    }

    // MARK: - Summary shaped by mode

    func test_summary_interviewIsDebrief_othersAreMinutes() {
        let interview = PromptCatalogue.summary(for: .interview)
        XCTAssertTrue(interview.contains("QUALITATIVE RESEARCH DEBRIEF"))

        for kind in [ModeKind.meeting, .coding, .other] {
            let s = PromptCatalogue.summary(for: kind)
            XCTAssertTrue(s.contains("writing the meeting record of this ENTIRE meeting"),
                          "expected minutes for \(kind)")
            XCTAssertNotEqual(s, interview)
        }
    }

    // MARK: - Listener research actions

    func test_listenerResearchPrompts() {
        XCTAssertTrue(PromptCatalogue.keyTensions.contains("KEY TENSIONS"))
        XCTAssertTrue(PromptCatalogue.probe.contains("LEFT UNSAID"))
        XCTAssertTrue(PromptCatalogue.themes.contains("EMERGING THEMES"))
    }

    // MARK: - System

    func test_systemPrompt_present() {
        XCTAssertTrue(PromptCatalogue.system.contains("You are RTI, a real-time meeting assistant"))
        XCTAssertTrue(PromptCatalogue.system.contains("## User notes"))
    }
}
