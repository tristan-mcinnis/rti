import XCTest
import RTICore

final class AssistantTurnBuilderTests: XCTestCase {
    private func build(
        action: String = "Ask",
        transcript: String = "",
        scope: String? = nil,
        hasWorkstream: Bool = false,
        listenerMode: Bool = false,
        referencedDocumentsText: String? = nil
    ) -> AssistantTurnBuilder.Output {
        AssistantTurnBuilder.build(.init(
            userInput: "What should I say?",
            action: action,
            transcript: transcript,
            fullTranscript: false,
            workstreamScopePath: scope,
            hasWorkstreamName: hasWorkstream,
            priorSuggestions: "Ask about timing",
            hasReferencedDocuments: referencedDocumentsText != nil,
            retrievalContext: "Vault search ran for this question (searched: 0 results).",
            guideCoverage: "Guide coverage: pricing is unanswered",
            baseSystemPrompt: "Base system",
            listenerSystemSuffix: "Listener suffix",
            listenerMode: listenerMode,
            meetingContext: "Meeting context",
            meetingBrief: "Prep brief",
            discussionGuide: "Discussion guide",
            glossaryFragment: "Glossary",
            referenceText: "Reference",
            referenceModeName: "Mode",
            screenContext: nil,
            referencedDocumentsText: referencedDocumentsText,
            existingEntries: []
        ))
    }

    func testBuildsTranscriptBackedUserMessageWithScopeInstruction() {
        let output = build(transcript: "Client: We need pricing.", scope: "projects/acme")

        XCTAssertTrue(output.contextUsed)
        let latest = output.apiMessages.last?.content ?? ""
        XCTAssertTrue(latest.contains("Recent conversation (last 15 minutes, diarized):"))
        XCTAssertTrue(latest.contains("Project scope is set to `projects/acme`"))
        XCTAssertTrue(latest.contains("You already suggested"))
        XCTAssertTrue(latest.contains("Vault search ran for this question"))
    }

    func testGuideCoverageOnlyAddedForGuideAwareActions() {
        let ask = build(action: "Ask")
        let assist = build(action: "Assist")

        XCTAssertFalse((ask.apiMessages.last?.content ?? "").contains("Guide coverage"))
        XCTAssertTrue((assist.apiMessages.last?.content ?? "").contains("Guide coverage"))
    }

    func testListenerModeAddsSuffixAndSkipsMeetingBrief() {
        let output = build(listenerMode: true)
        let systemMessages = output.apiMessages.filter { $0.role == "system" }.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(systemMessages.contains("Base system"))
        XCTAssertTrue(systemMessages.contains("Listener suffix"))
        XCTAssertFalse(systemMessages.contains("Prep brief"))
    }

    func testReferencedDocumentInstructionAndSystemMessageAreAdded() {
        let output = build(referencedDocumentsText: "Doc body")
        let latest = output.apiMessages.last?.content ?? ""
        let systemMessages = output.apiMessages.filter { $0.role == "system" }.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(latest.contains("The user explicitly attached source material"))
        XCTAssertTrue(systemMessages.contains("Doc body"))
    }
}
