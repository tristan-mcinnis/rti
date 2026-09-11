import RTICore
import XCTest

/// The composer's words: the placeholder, the action drawn inside the field,
/// the slash catalogue, and the attachment chip details
/// (chat-surfaces.md section 3 and 4; RTI plan section 4).
final class ComposerStateTests: XCTestCase {
    // MARK: - Action inside the field

    func test_emptyField_namesThePrimaryActionOnCommandReturn() {
        let state = ComposerState(primaryActionLabel: "Assist")
        XCTAssertEqual(state.action, ComposerAction(kind: .runPrimary, label: "Assist", keys: ["⌘", "↩"]))

        let recap = ComposerState(primaryActionLabel: "Recap")
        XCTAssertEqual(recap.action.label, "Recap")
    }

    func test_typedText_asksOnReturn() {
        let state = ComposerState(draft: "What did we decide?")
        XCTAssertEqual(state.action, ComposerAction(kind: .ask, label: "Ask", keys: ["↩"]))
    }

    func test_whitespaceOnly_countsAsEmpty() {
        let state = ComposerState(draft: "  \n ")
        XCTAssertEqual(state.action.kind, .runPrimary)
        XCTAssertFalse(state.canSubmit)
    }

    func test_chipsOnTheirOwn_askOnReturn() {
        let state = ComposerState(hasAttachments: true)
        XCTAssertEqual(state.action.label, "Ask")
        XCTAssertTrue(state.canSubmit)
    }

    func test_typedSlashCommand_runs() {
        XCTAssertEqual(ComposerState(draft: "/search pricing").action.label, "Run")
    }

    func test_streaming_stopsOnEscape_andQueuedSaysSo() {
        let streaming = ComposerState(draft: "", isStreaming: true)
        XCTAssertEqual(streaming.action, ComposerAction(kind: .stop, label: "Stop", keys: ["esc"]))

        let typing = ComposerState(draft: "and the budget?", isStreaming: true)
        XCTAssertEqual(typing.action.kind, .stop, "typing alone does not queue")

        let queued = ComposerState(draft: "and the budget?", isStreaming: true, isQueued: true)
        XCTAssertEqual(queued.action, ComposerAction(kind: .queued, label: "Queued", keys: ["↩"]))
    }

    func test_noteMode_addsANote_evenWhileStreaming() {
        let note = ComposerState(isNoteMode: true)
        XCTAssertEqual(note.action, ComposerAction(kind: .addNote, label: "Add Note", keys: ["↩"]))

        let duringStream = ComposerState(draft: "Pricing agreed", isStreaming: true, isNoteMode: true)
        XCTAssertEqual(duringStream.action.kind, .addNote)
        XCTAssertFalse(duringStream.returnQueues, "a note never waits on an answer")
    }

    func test_openChooser_namesItsOwnVerb() {
        XCTAssertEqual(ComposerState(draft: "@onb", layer: .mention).action.label, "Add")
        XCTAssertEqual(ComposerState(layer: .addContext).action.label, "Add")
        XCTAssertEqual(ComposerState(draft: "/re", layer: .slash).action.label, "Run")
        XCTAssertEqual(ComposerState(layer: .palette).action.label, "Run")
        XCTAssertEqual(ComposerState(isStreaming: true, layer: .mention).action.kind, .acceptChooser)
    }

    // MARK: - Placeholder

    func test_placeholder_followsTheState() {
        XCTAssertEqual(ComposerState().placeholder, "Ask the vault, @ a file, or / for commands…")
        XCTAssertEqual(ComposerState(isRecording: true).placeholder, "Ask about this meeting…")
        XCTAssertEqual(ComposerState(isNoteMode: true, isRecording: true).placeholder, "Note to the transcript…")
        XCTAssertEqual(ComposerState(isNoteMode: true).placeholder, "Prep note for this meeting…")
        XCTAssertEqual(
            ComposerState(isStreaming: true, isRecording: true).placeholder,
            "Type a follow-up; it sends when this answer ends"
        )
    }

    func test_noEmDashInAnyComposerWords() {
        let words = [
            ComposerState.idlePlaceholder, ComposerState.recordingPlaceholder,
            ComposerState.transcriptNotePlaceholder, ComposerState.prepNotePlaceholder,
            ComposerState.streamingPlaceholder,
        ] + ComposerSlashCommand.all.map(\.help)
        for word in words {
            XCTAssertFalse(word.contains("\u{2014}"), word)
        }
    }

    // MARK: - Queue

    func test_returnQueues_onlyWithSomethingToSendDuringAStream() {
        XCTAssertTrue(ComposerState(draft: "next?", isStreaming: true).returnQueues)
        XCTAssertTrue(ComposerState(hasAttachments: true, isStreaming: true).returnQueues)
        XCTAssertFalse(ComposerState(isStreaming: true).returnQueues)
        XCTAssertFalse(ComposerState(draft: "next?").returnQueues)
    }

    // MARK: - Slash commands

    func test_slashCatalogue_keepsAllFifteenCommandsAndTheirAliases() {
        XCTAssertEqual(ComposerSlashCommand.all.count, 15)
        let aliases: [String: String] = [
            "latest": "answer", "saynext": "say", "followup": "followups", "summarize": "summary",
            "grep": "search", "rag": "search", "source": "sources", "client": "project",
            "context": "project", "?": "help", "clear": "new",
        ]
        for (alias, id) in aliases {
            XCTAssertEqual(ComposerSlashCommand.command(named: alias)?.id, id, alias)
        }
        XCTAssertEqual(ComposerSlashCommand.command(named: "RECAP")?.id, "recap")
        XCTAssertNil(ComposerSlashCommand.command(named: "nope"))
    }

    func test_slashChooser_showsForOneWordOnly() {
        XCTAssertTrue(ComposerSlashCommand.isChooserDraft("/"))
        XCTAssertTrue(ComposerSlashCommand.isChooserDraft("/rec"))
        XCTAssertFalse(ComposerSlashCommand.isChooserDraft("/search pricing"))
        XCTAssertFalse(ComposerSlashCommand.isChooserDraft("search"))
    }

    func test_slashMatches_filterByIdAliasOrLabel() {
        XCTAssertEqual(ComposerSlashCommand.matches("/").count, 15)
        XCTAssertEqual(ComposerSlashCommand.matches("/rec").map(\.id), ["recap", "recent"])
        XCTAssertEqual(ComposerSlashCommand.matches("/grep").map(\.id), ["search"])
        XCTAssertEqual(ComposerSlashCommand.matches("/follow").map(\.id), ["followups"])
    }

    // MARK: - Attachment words

    func test_chipDetail_pdfTextVaultAndScreen() {
        let pdf = ChatAttachmentRef(kind: .pdf, name: "Launch plan.pdf", byteCount: 84_000, pageCount: 12)
        XCTAssertEqual(ComposerAttachmentDetail.detail(for: pdf), "12 pp · 84 KB")
        XCTAssertEqual(ComposerAttachmentDetail.spokenDetail(for: pdf), "12 pages, 84 KB")

        let cut = ChatAttachmentRef(kind: .text, name: "Survey export.txt", byteCount: 480_000, wasCut: true)
        XCTAssertEqual(ComposerAttachmentDetail.detail(for: cut), "480 KB · cut")

        let vault = ChatAttachmentRef(kind: .vaultFile, name: "onboarding-brief.md", path: "projects/northwind/onboarding-brief.md")
        XCTAssertEqual(ComposerAttachmentDetail.detail(for: vault), "")
        XCTAssertEqual(ComposerAttachmentDetail.spokenDetail(for: vault), "projects/northwind/onboarding-brief.md")

        XCTAssertEqual(ComposerAttachmentDetail.detail(for: ChatAttachmentRef(kind: .screen, name: "Screen")), "once")
    }

    func test_byteText_decimalUnitsLikeFinder() {
        XCTAssertEqual(ComposerAttachmentDetail.byteText(1), "1 byte")
        XCTAssertEqual(ComposerAttachmentDetail.byteText(999), "999 bytes")
        XCTAssertEqual(ComposerAttachmentDetail.byteText(18_400), "18 KB")
        XCTAssertEqual(ComposerAttachmentDetail.byteText(524_288), "524 KB")
        XCTAssertEqual(ComposerAttachmentDetail.byteText(1_200_000), "1.2 MB")
    }
}
