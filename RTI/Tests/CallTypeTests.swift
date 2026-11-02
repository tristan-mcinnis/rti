import RTICore
import XCTest

/// Pins what choosing a call type changes: the prompt, the listener framing,
/// the ✦ menu, the tools a live turn may reach, and what `/meeting` is told.
final class CallTypeTests: XCTestCase {
    func testEachTypeHasItsOwnPrompt() {
        let prompts = CallType.allCases.map(\.prompt.defaultText)
        XCTAssertEqual(Set(prompts).count, CallType.allCases.count)
        XCTAssertFalse(prompts.contains { $0.isEmpty })
    }

    func testAResearchCallAsksForOpenQuestions() {
        XCTAssertTrue(CallType.research.prompt.defaultText.contains("never leading"))
        XCTAssertFalse(CallType.client.prompt.defaultText.contains("never leading"))
    }

    func testOnlyAResearchCallListens() {
        XCTAssertEqual(CallType.allCases.filter(\.listens), [.research])
    }

    func testEachMenuListsRealActions() {
        for type in CallType.allCases {
            XCTAssertFalse(type.menuActions.isEmpty, type.name)
            XCTAssertEqual(type.menuActions.count, type.menuActionIDs.count, type.name)
        }
    }

    func testTheMenusFitTheCall() {
        XCTAssertEqual(CallType.client.menuActionIDs.first, "assist")
        XCTAssertEqual(CallType.research.menuActionIDs.first, "probe")
        XCTAssertEqual(CallType.internal.menuActionIDs.first, "quickRecap")
        XCTAssertFalse(CallType.client.menuActionIDs.contains("probe"))
        XCTAssertFalse(CallType.research.menuActionIDs.contains("assist"))
    }

    func testAnUnknownStoredValueFallsBackToClient() {
        XCTAssertEqual(CallType.resolve(stored: nil), .client)
        XCTAssertEqual(CallType.resolve(stored: "builtin.meeting"), .client)
        XCTAssertEqual(CallType.resolve(stored: "research"), .research)
    }

    func testALiveClientCallOnlySearchesWhenAsked() {
        let open = ChatToolPolicy(allowsExternalRetrieval: true)
        XCTAssertFalse(open.forLiveCall(question: "what does the launch plan cover?", callType: .client).allowsExternalRetrieval)
        XCTAssertTrue(open.forLiveCall(question: "search for the launch plan", callType: .client).allowsExternalRetrieval)
        XCTAssertTrue(open.forLiveCall(question: "search for the guide", callType: .research).allowsExternalRetrieval)
        XCTAssertTrue(open.forLiveCall(question: "what did we decide last time?", callType: .internal).allowsExternalRetrieval)
    }

    func testAPersonalCallNeverOpensTheWorkFiles() {
        let open = ChatToolPolicy(allowsExternalRetrieval: true)
        XCTAssertFalse(open.forLiveCall(question: "search for the launch plan", callType: .personal).allowsExternalRetrieval)
    }

    func testTheSidecarNamesTheType() {
        XCTAssertEqual(CallType.research.sidecarField, "call_type: research")
        XCTAssertEqual(CallType.internal.sidecarField, "call_type: internal")
    }
}
