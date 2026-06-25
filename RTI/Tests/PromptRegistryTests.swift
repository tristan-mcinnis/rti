import RTICore
import XCTest

/// Pins the prompt registry (`PromptID`/`PromptDefaults`) and the composition
/// seam (`PromptComposer`) that `PromptStore` resolves overrides through. The
/// app-side override store is UserDefaults-backed and exercised in the app; here
/// we prove the pure layer it stands on.
final class PromptRegistryTests: XCTestCase {
    // MARK: - Registry completeness

    func test_everyPromptHasNonEmptyDefault() {
        for id in PromptID.allCases {
            XCTAssertFalse(id.defaultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(id.rawValue) has an empty default")
            XCTAssertFalse(id.title.isEmpty)
            XCTAssertFalse(id.help.isEmpty)
        }
    }

    func test_exportMapCoversAllCases() {
        let map = PromptDefaults.exportMap()
        XCTAssertEqual(map.count, PromptID.allCases.count)
        for id in PromptID.allCases {
            XCTAssertEqual(map[id.rawValue], id.defaultText)
        }
    }

    // MARK: - Contract metadata (drives the editor's warnings)

    func test_jsonContractPromptsRequireJSONToken() {
        let json: Set<PromptID> = [.findingsLedger, .autoAssistCards, .dgParse, .dgMatch]
        for id in PromptID.allCases {
            XCTAssertEqual(id.isJSONContract, json.contains(id), "isJSONContract wrong for \(id.rawValue)")
            if id.isJSONContract {
                XCTAssertTrue(id.requiredTokens.contains("JSON"))
                XCTAssertTrue(id.defaultText.contains("JSON"), "\(id.rawValue) default lost its JSON instruction")
            }
        }
        XCTAssertEqual(PromptID.liveNotes.requiredTokens, ["TITLE:"])
        XCTAssertTrue(PromptID.liveNotes.defaultText.contains("TITLE:"))
    }

    // MARK: - Drift hash

    func test_fnv1aIsStableAndDistinct() {
        XCTAssertEqual(PromptDefaults.fnv1a("hello"), PromptDefaults.fnv1a("hello"))
        XCTAssertNotEqual(PromptDefaults.fnv1a("hello"), PromptDefaults.fnv1a("hellp"))
        // defaultHash tracks the default text.
        XCTAssertEqual(PromptID.systemDefault.defaultHash,
                       PromptDefaults.fnv1a(PromptID.systemDefault.defaultText))
    }

    // MARK: - Composition seam (how overrides flow through)

    func test_recapComposesClauseAndLanguageRuleFromResolver() {
        // A resolver that swaps the standard clause proves the override path.
        let resolve: PromptComposer.Resolver = { id in
            id == .recapStandard ? "CUSTOM_CLAUSE" : id.defaultText
        }
        let composed = PromptComposer.recap(.standard, resolve: resolve)
        XCTAssertTrue(composed.hasPrefix("Recap the conversation so far "))
        XCTAssertTrue(composed.contains("CUSTOM_CLAUSE"))
        XCTAssertTrue(composed.contains("Reply in ENGLISH regardless"))
        // Default resolver still yields the shipped prompt.
        XCTAssertEqual(PromptComposer.recap(.standard), PromptCatalogue.recap(.standard))
    }

    func test_recapClauseIDMapsDepths() {
        XCTAssertEqual(PromptComposer.recapClauseID(for: .brief), .recapBrief)
        XCTAssertEqual(PromptComposer.recapClauseID(for: .standard), .recapStandard)
        XCTAssertEqual(PromptComposer.recapClauseID(for: .detailed), .recapDetailed)
    }

    func test_assistAndFollowupsSwitchOnListener() {
        XCTAssertEqual(PromptComposer.assist(listener: false), PromptID.assistSpeaker.defaultText)
        XCTAssertEqual(PromptComposer.assist(listener: true), PromptID.listenerAssist.defaultText)
        XCTAssertEqual(PromptComposer.followups(listener: false), PromptID.followupsSpeaker.defaultText)
        XCTAssertEqual(PromptComposer.followups(listener: true), PromptID.listenerFollowups.defaultText)
    }

    func test_summarySwitchesOnMode() {
        XCTAssertEqual(PromptComposer.summary(for: .interview), PromptID.interviewSummary.defaultText)
        for kind in [ModeKind.meeting, .coding, .other] {
            XCTAssertEqual(PromptComposer.summary(for: kind), PromptID.meetingSummary.defaultText)
        }
    }

    /// A resolver substitution flows through every composed prompt — the
    /// guarantee `PromptStore` relies on to make overrides take effect.
    func test_resolverOverrideFlowsThroughComposition() {
        let resolve: PromptComposer.Resolver = { _ in "X" }
        XCTAssertEqual(PromptComposer.assist(listener: true, resolve: resolve), "X")
        XCTAssertEqual(PromptComposer.summary(for: .interview, resolve: resolve), "X")
        XCTAssertEqual(PromptComposer.recap(.brief, resolve: resolve), "Recap the conversation so far X X")
    }
}
