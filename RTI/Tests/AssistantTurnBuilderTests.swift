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
        images: [LLMImage] = [],
        referencedDocumentsText: String? = nil,
        sourceContext: TurnSourceContext? = nil,
        externalRetrievalAllowed: Bool = false
    ) -> AssistantTurnBuilder.Output {
        let sources = sourceContext
            ?? TurnSourceContext(freshCount: referencedDocumentsText == nil ? 0 : 1)
        return AssistantTurnBuilder.build(.init(
            userInput: "What should I say?",
            action: action,
            transcript: transcript,
            fullTranscript: false,
            transcriptWindowMinutes: transcriptWindowMinutes,
            workstreamScopePath: scope,
            hasWorkstreamName: hasWorkstream,
            priorSuggestions: "Ask about timing",
            sourceContext: sources,
            externalRetrievalAllowed: externalRetrievalAllowed,
            retrievalContext: "Vault search ran for this question (searched: 0 results).",
            baseSystemPrompt: "Base system",
            listenerSystemSuffix: "Listener suffix",
            listenerMode: listenerMode,
            meetingContext: "Meeting context",
            meetingBrief: "Prep brief",
            glossaryFragment: "Glossary",
            referenceText: "Reference",
            referenceModeName: "Mode",
            screenContext: nil,
            images: images,
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
        let output = build(transcript: "Client: hello", images: [image])
        let latest = output.apiMessages.last
        XCTAssertEqual(latest?.role, "user")
        XCTAssertEqual(latest?.images?.count, 1)
        // The system messages never carry the image.
        XCTAssertTrue(output.apiMessages.filter { $0.role == "system" }.allSatisfy { ($0.images?.isEmpty ?? true) })
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

    /// A bare follow-up re-sends this chat's retained sources. The prompt must
    /// say so, and must not call them newly attached for this turn.
    func testARetainedSourceIsNotDescribedAsAttachedForThisTurn() {
        let output = build(
            referencedDocumentsText: "Doc body",
            sourceContext: TurnSourceContext(freshCount: 0, retainedCount: 1)
        )
        let latest = output.apiMessages.last?.content ?? ""
        XCTAssertFalse(latest.contains("for this turn"))
        XCTAssertTrue(latest.contains("earlier turns"))
    }

    /// When the user widened the search, the prompt must not forbid what the
    /// tool list permits.
    func testAWidenedSearchIsNotForbiddenByThePrompt() {
        let output = build(
            referencedDocumentsText: "Doc body",
            sourceContext: TurnSourceContext(freshCount: 0, retainedCount: 1),
            externalRetrievalAllowed: true
        )
        let latest = output.apiMessages.last?.content ?? ""
        XCTAssertFalse(latest.contains("Do not search the vault"))
        XCTAssertTrue(latest.contains("the vault tools are available too"))
    }

    func testNoSourceMeansNoSourceSentence() {
        let latest = build().apiMessages.last?.content ?? ""
        XCTAssertFalse(latest.contains("attached source material"))
        XCTAssertFalse(latest.contains("Do not search the vault"))
    }
}
