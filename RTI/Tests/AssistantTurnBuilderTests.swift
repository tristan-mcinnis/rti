import XCTest
import RTICore

final class AssistantTurnBuilderTests: XCTestCase {
    private func build(
        action: String = "Ask",
        transcript: String = "",
        transcriptWindowMinutes: Int = 15,
        scope: String? = nil,
        hasWorkstream: Bool = false,
        listenerMode: Bool = false,
        screenImage: LLMImage? = nil,
        referencedDocumentsText: String? = nil
    ) -> AssistantTurnBuilder.Output {
        AssistantTurnBuilder.build(.init(
            userInput: "What should I say?",
            action: action,
            transcript: transcript,
            fullTranscript: false,
            transcriptWindowMinutes: transcriptWindowMinutes,
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
            screenImage: screenImage,
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

    func testQuickRecapLabelsItsShorterWindow() {
        // Quick recap reads 5 minutes; the prompt label must match the window
        // the turn actually carries, not the 15-minute default.
        let quick = build(action: "Quick recap", transcript: "Client: We need pricing.", transcriptWindowMinutes: 5)
        let labelled = quick.apiMessages.last?.content ?? ""
        XCTAssertTrue(labelled.contains("Recent conversation (last 5 minutes, diarized):"))
        XCTAssertFalse(labelled.contains("last 15 minutes"))
        let standard = build(transcript: "x", transcriptWindowMinutes: 15).apiMessages.last?.content ?? ""
        XCTAssertTrue(standard.contains("last 15 minutes"))
    }

    func testScreenImageRidesTheLatestUserMessage() {
        let image = LLMImage(jpegData: Data([0x01]))
        let output = build(transcript: "Client: hello", screenImage: image)
        let latest = output.apiMessages.last
        XCTAssertEqual(latest?.role, "user")
        XCTAssertEqual(latest?.images?.count, 1)
        // The system messages never carry the image.
        XCTAssertTrue(output.apiMessages.filter { $0.role == "system" }.allSatisfy { ($0.images?.isEmpty ?? true) })
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
