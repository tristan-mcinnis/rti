import XCTest
@testable import RTICore

/// Unknown slash commands stay local: the composer names the literal send
/// instead of running anything, `Return` and `⌘Return` never send the words,
/// and only the explicit Send as Text action does.
final class ComposerUnknownCommandTests: XCTestCase {

    func testKnownCommandKeepsTheRunVerb() {
        let state = ComposerState(draft: "/recap")
        XCTAssertEqual(state.action.kind, .ask)
        XCTAssertEqual(state.action.label, "Run")
    }

    func testKnownAliasStillRuns() {
        XCTAssertEqual(ComposerState(draft: "/summarize").action.label, "Run")
        XCTAssertEqual(ComposerState(draft: "/grep budget").action.label, "Run")
    }

    func testUnknownCommandOffersSendAsTextWithNoKey() {
        let state = ComposerState(draft: "/deploy now")
        XCTAssertEqual(state.action.kind, .sendAsText)
        XCTAssertEqual(state.action.label, "Send as Text")
        // No key caps: Return is not a way to send the words. Only the
        // explicit action is.
        XCTAssertEqual(state.action.keys, [])
    }

    func testUnknownSingleWordCommandOffersSendAsText() {
        XCTAssertEqual(ComposerState(draft: "/foo").action.kind, .sendAsText)
    }

    func testPlainTextStillAsks() {
        let state = ComposerState(draft: "what did we decide?")
        XCTAssertEqual(state.action.kind, .ask)
        XCTAssertEqual(state.action.label, "Ask")
    }

    func testABareSlashIsNotACommandWord() {
        XCTAssertNil(ComposerState.leadingCommandWord(in: "/"))
        XCTAssertNil(ComposerState.leadingCommandWord(in: "hello"))
        XCTAssertEqual(ComposerState.leadingCommandWord(in: "/recap "), "recap")
        XCTAssertEqual(ComposerState.leadingCommandWord(in: "/deploy\nmore"), "deploy")
    }

    func testTheSlashChooserStillOpensWhileTyping() {
        // The chooser owns the layer, and its own verb wins, before the
        // send-as-text wording is ever consulted.
        XCTAssertTrue(ComposerSlashCommand.isChooserDraft("/rec"))
        let state = ComposerState(draft: "/rec", layer: .slash)
        XCTAssertEqual(state.action.kind, .acceptChooser)
        XCTAssertEqual(state.action.label, "Run")
    }

    func testAnUnknownCommandIsNeverSentByReturn() {
        let state = ComposerState(draft: "/foo bar")
        XCTAssertTrue(state.isUnknownSlashCommand)
        XCTAssertFalse(state.canSubmit, "Return does nothing: the line stays local")
        XCTAssertFalse(state.returnQueues, "and it does not queue behind a stream either")
    }

    func testOnlyAnUnknownLineIsRefused() {
        XCTAssertFalse(ComposerState(draft: "/recap").isUnknownSlashCommand)
        XCTAssertFalse(ComposerState(draft: "/summarize").isUnknownSlashCommand)
        XCTAssertFalse(ComposerState(draft: "/clear").isUnknownSlashCommand)
        XCTAssertFalse(ComposerState(draft: "/").isUnknownSlashCommand, "a bare slash is not a command word")
        XCTAssertFalse(ComposerState(draft: "what did we decide?").isUnknownSlashCommand)
        XCTAssertTrue(ComposerState(draft: "/deploy").isUnknownSlashCommand)
        XCTAssertTrue(ComposerState(draft: "  /deploy now  ").isUnknownSlashCommand)
    }
}
