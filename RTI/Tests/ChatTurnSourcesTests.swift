import XCTest
@testable import RTICore

/// The wire set and the context decision are composed together. These pin the
/// four source situations a chat can be in, and the agreement between the
/// prompt sentence, the tool policy and the receipt that the composition is
/// there to guarantee.
final class ChatTurnSourcesTests: XCTestCase {

    private struct Fixture {
        let name: String
        let question: String
        let fresh: Int
        let retained: Int
        let historyTurns: Int
        let historyHasSources: Bool
        let broader: Bool
    }

    private let fixtures: [Fixture] = [
        Fixture(
            name: "fresh source",
            question: "what number is in this file?",
            fresh: 1, retained: 0, historyTurns: 0, historyHasSources: false, broader: false
        ),
        Fixture(
            name: "bare follow-up with a retained source",
            question: "and what else?",
            fresh: 0, retained: 1, historyTurns: 2, historyHasSources: true, broader: false
        ),
        Fixture(
            name: "fresh source and a retained one compared",
            question: "compare this with the earlier file",
            fresh: 1, retained: 1, historyTurns: 2, historyHasSources: true, broader: false
        ),
        Fixture(
            name: "post-reset bare question",
            question: "what next?",
            fresh: 0, retained: 0, historyTurns: 0, historyHasSources: false, broader: false
        ),
        Fixture(
            name: "broader search over a retained source",
            question: "and what else?",
            fresh: 0, retained: 1, historyTurns: 2, historyHasSources: true, broader: true
        ),
        Fixture(
            name: "question that names the vault with a fresh source",
            question: "check the vault for the earlier decision",
            fresh: 1, retained: 0, historyTurns: 0, historyHasSources: false, broader: false
        ),
    ]

    private func compose(_ fixture: Fixture) -> ChatWireSources {
        ChatWireSources.compose(
            question: fixture.question,
            freshSourceCount: fixture.fresh,
            retainedSourceCount: fixture.retained,
            historyTurnCount: fixture.historyTurns,
            historyHasSources: fixture.historyHasSources,
            broaderToggleOn: fixture.broader
        )
    }

    // MARK: The four choices

    func testAFreshSourceIsAnsweredFromItself() {
        let wire = compose(fixtures[0])
        XCTAssertEqual(wire.choice, .fresh)
        XCTAssertEqual(wire.wireSourceCount, 1)
        XCTAssertTrue(wire.carriesFreshSources)
        XCTAssertFalse(wire.carriesRetainedSources)
        XCTAssertFalse(wire.decision.allowsExternalRetrieval, "a fresh source grounds the turn")
    }

    func testABareFollowUpReadsTheRetainedArchive() {
        let wire = compose(fixtures[1])
        XCTAssertEqual(wire.choice, .retained, "nothing new to send, so the chat's own archive answers")
        XCTAssertEqual(wire.wireSourceCount, 1)
        XCTAssertTrue(wire.carriesRetainedSources)
        XCTAssertFalse(wire.carriesFreshSources)
        XCTAssertGreaterThan(wire.wireSourceCount, 0)
        XCTAssertNotEqual(wire.decision.execution, .none, "the receipt must not say no source while one is on the wire")
        XCTAssertFalse(wire.decision.allowsExternalRetrieval)
    }

    func testAComparisonCarriesBothSets() {
        let wire = compose(fixtures[2])
        XCTAssertEqual(wire.choice, .freshAndRetained)
        XCTAssertEqual(wire.wireSourceCount, 2)
        XCTAssertTrue(wire.decision.includesHistory)
        XCTAssertEqual(wire.decision.execution, .currentSourceAndHistory)
    }

    func testAfterAResetNothingIsOnTheWireAndNothingIsRecorded() {
        let wire = compose(fixtures[3])
        XCTAssertEqual(wire.choice, .none)
        XCTAssertEqual(wire.wireSourceCount, 0)
        XCTAssertEqual(wire.decision.execution, .none, "ordinary chat with no source is the receipt's own scope")
        XCTAssertTrue(wire.decision.allowsExternalRetrieval)
    }

    func testBroaderSearchWidensWithoutLosingTheSource() {
        let wire = compose(fixtures[4])
        XCTAssertEqual(wire.choice, .retained)
        XCTAssertTrue(wire.carriesSources)
        XCTAssertTrue(wire.decision.allowsExternalRetrieval, "the override lifts the withholding")
    }

    func testNamingTheVaultLiftsTheWithholdingOnAFreshSourceTurn() {
        let wire = compose(fixtures[5])
        XCTAssertEqual(wire.choice, .fresh)
        XCTAssertTrue(wire.decision.allowsExternalRetrieval)
    }

    // MARK: The invariant: one set, described the same way everywhere

    func testTheReceiptScopeAlwaysAgreesWithTheWire() {
        for fixture in fixtures {
            let wire = compose(fixture)
            if wire.carriesSources {
                XCTAssertNotEqual(
                    wire.decision.execution, .none,
                    "\(fixture.name): a source on the wire cannot be recorded as no source"
                )
            } else {
                XCTAssertEqual(
                    wire.decision.execution, .none,
                    "\(fixture.name): no source on the wire must be recorded as no source"
                )
            }
            XCTAssertEqual(
                wire.carriesSources,
                wire.decision.execution != .none,
                "\(fixture.name): scope and wire disagree"
            )
        }
    }

    func testThePromptInstructionAppearsExactlyWhenASourceIsOnTheWire() {
        for fixture in fixtures {
            let wire = compose(fixture)
            let instruction = TurnSourceInstruction.text(
                for: TurnSourceContext(
                    freshCount: wire.carriesFreshSources ? fixture.fresh : 0,
                    retainedCount: wire.carriesRetainedSources ? fixture.retained : 0
                ),
                externalRetrievalAllowed: wire.decision.allowsExternalRetrieval
            )
            XCTAssertEqual(
                instruction != nil,
                wire.carriesSources,
                "\(fixture.name): the source sentence and the wire disagree"
            )
        }
    }

    /// The prompt may forbid a vault search only when the tool policy withheld
    /// the vault tools, and vice versa. This is the C1/C3 agreement.
    func testThePromptForbiddingASearchMatchesTheToolPolicy() {
        for fixture in fixtures {
            let wire = compose(fixture)
            let policy = ChatToolPolicy(decision: wire.decision)
            let instruction = TurnSourceInstruction.text(
                for: TurnSourceContext(
                    freshCount: wire.carriesFreshSources ? fixture.fresh : 0,
                    retainedCount: wire.carriesRetainedSources ? fixture.retained : 0
                ),
                externalRetrievalAllowed: wire.decision.allowsExternalRetrieval
            ) ?? ""
            let promptForbids = instruction.contains("Do not search the vault")
            XCTAssertEqual(
                promptForbids,
                !policy.allowsExternalRetrieval,
                "\(fixture.name): prompt says forbid=\\(promptForbids), policy allows=\\(policy.allowsExternalRetrieval)"
            )
            XCTAssertEqual(policy.allowsDiscovery, wire.decision.allowsExternalRetrieval)
            XCTAssertEqual(policy.allowsTool(named: "search_vault"), policy.allowsExternalRetrieval)
        }
    }

    /// Only a source attached for THIS turn may be called new; a retained one
    /// may never be described as attached for this turn.
    func testOnlyAFreshSourceIsDescribedAsForThisTurn() {
        let retained = TurnSourceInstruction.text(
            for: TurnSourceContext(freshCount: 0, retainedCount: 1),
            externalRetrievalAllowed: false
        ) ?? ""
        XCTAssertFalse(retained.contains("for this turn"), "a retained source is not new")
        XCTAssertTrue(retained.contains("earlier turns"))
        XCTAssertTrue(retained.contains("do not describe it as newly attached"))

        let fresh = TurnSourceInstruction.text(
            for: TurnSourceContext(freshCount: 1, retainedCount: 0),
            externalRetrievalAllowed: false
        ) ?? ""
        XCTAssertTrue(fresh.contains("for this turn"))

        let both = TurnSourceInstruction.text(
            for: TurnSourceContext(freshCount: 1, retainedCount: 1),
            externalRetrievalAllowed: false
        ) ?? ""
        XCTAssertTrue(both.contains("newly attached"))
        XCTAssertTrue(both.contains("retained"))
    }

    func testNoSourceMeansNoSourceSentence() {
        XCTAssertNil(TurnSourceInstruction.text(for: TurnSourceContext(), externalRetrievalAllowed: true))
        XCTAssertNil(TurnSourceInstruction.text(for: TurnSourceContext(), externalRetrievalAllowed: false))
    }
}
