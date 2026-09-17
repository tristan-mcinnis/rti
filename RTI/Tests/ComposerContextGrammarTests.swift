import RTICore
import XCTest

/// The one grammar `@` in the field and the `+` Add Context pane share
/// (`ComposerMention`): what the words after the `@` mean, how a chosen path is
/// written into the question, and that a quoted mention typed by hand is a
/// path and not a search.
final class ComposerContextGrammarTests: XCTestCase {

    // MARK: - Typing

    func testTheQueryIsWhatFollowsTheAt() {
        XCTAssertEqual(ComposerMention.query(in: "@onb"), "onb")
        XCTAssertEqual(ComposerMention.query(in: "@two words"), "two words")
        // The whole tail is the query, the way the vault index is searched.
        XCTAssertEqual(ComposerMention.query(in: "Summarize @northwind for me"), "northwind for me")
        // A bare `@` opens the chooser on the keystroke itself.
        XCTAssertEqual(ComposerMention.query(in: "@"), "")
    }

    func testNoAtMeansNoChooser() {
        XCTAssertNil(ComposerMention.query(in: "what did we decide?"))
        XCTAssertFalse(ComposerMention.isOpen(in: "what did we decide?"))
        XCTAssertTrue(ComposerMention.isOpen(in: "@"), "the chooser opens on the @ itself")
    }

    func testAMentionNeverSpansALine() {
        XCTAssertNil(ComposerMention.query(in: "@northwind\nnext line"))
        XCTAssertEqual(ComposerMention.query(in: "@one @two"), "two",
                       "a second @ restarts the mention being typed")
    }

    // MARK: - Quoted mentions

    func testATypedQuoteClosesTheChooser() {
        // The words between the quotes are the path itself, so nothing is
        // being searched and the chooser must not open over it.
        XCTAssertNil(ComposerMention.query(in: "@\"projects/northwind/brief.md\""))
        XCTAssertNil(ComposerMention.query(in: "Compare @\"a file with spaces.md\" now"))
    }

    func testAPathIsWrittenQuoted() {
        XCTAssertEqual(ComposerMention.token(for: "projects/northwind/brief.md"),
                       "@\"projects/northwind/brief.md\"")
        XCTAssertEqual(ComposerMention.token(for: "a file with spaces.md"),
                       "@\"a file with spaces.md\"")
    }

    func testChosenPathsLeadTheQuestion() {
        XCTAssertEqual(
            ComposerMention.line(paths: ["projects/northwind/brief.md"], text: "Summarize this"),
            "@\"projects/northwind/brief.md\" Summarize this"
        )
        XCTAssertEqual(
            ComposerMention.line(paths: ["a.md", "b c.md"], text: ""),
            "@\"a.md\" @\"b c.md\""
        )
    }

    func testNoPathsLeavesTheQuestionAlone() {
        XCTAssertEqual(ComposerMention.line(paths: [], text: "Summarize this"), "Summarize this")
    }

    func testAQuotedMentionIsSubmittableTextEitherWay() {
        // The chooser is closed, but the draft is ordinary text: `↩` sends it.
        let state = ComposerState(draft: "@\"projects/northwind/brief.md\" summarize")
        XCTAssertFalse(state.isUnknownSlashCommand)
        XCTAssertTrue(state.canSubmit)
    }
}
