import RTICore
import XCTest

/// Reading an archived `chat.md` back into turns for the Sessions window's
/// read-only thread. The sample mirrors `SessionArchive.chatBlock`.
final class ArchivedChatTests: XCTestCase {
    private let sample = """
    ---
    title: "RTI session · 2026-09-12 10:30 · Chat"
    type: reference
    ---
    # Chat

    _2026-09-12 10:30 · 34m 0s_

    **You** _(Assist, transcript)_

    Assist

    **Assistant**

    They've just agreed to drop the guided tour.

    Worth raising now: who sets the threshold.

    **You** _(Ask, transcript, screen)_

    Referenced files:
    - `projects/northwind/onboarding-brief.md`

    What did we decide last time?

    **Assistant**

    Ship without the tour.
    """

    func testTurnsRolesAndText() {
        let turns = ArchivedChat.turns(fromMarkdown: sample)
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(turns[1].text, "They've just agreed to drop the guided tour.\n\nWorth raising now: who sets the threshold.")
        XCTAssertEqual(turns[3].text, "Ship without the tour.")
    }

    func testCannedActionShowsItsNameTypedQuestionShowsText() {
        let turns = ArchivedChat.turns(fromMarkdown: sample)
        XCTAssertEqual(turns[0].action, "Assist")
        XCTAssertEqual(turns[0].pillText, "Assist")
        XCTAssertTrue(turns[0].usedTranscript)
        XCTAssertFalse(turns[0].usedScreen)

        XCTAssertNil(turns[2].action, "Ask is a typed question, not a canned action")
        XCTAssertEqual(turns[2].pillText, "What did we decide last time?")
        XCTAssertTrue(turns[2].usedScreen)
        XCTAssertEqual(turns[2].referencedPaths, ["projects/northwind/onboarding-brief.md"])
    }

    func testCannedActionHidesAnInternalPrompt() {
        let turns = ArchivedChat.turns(fromMarkdown: "**You** _(Recap)_\n\nSummarise the last ten minutes as bullets for a busy exec.\n")
        XCTAssertEqual(turns.first?.pillText, "Recap")
    }

    func testSlashCommandShowsWhatWasTyped() {
        let turns = ArchivedChat.turns(fromMarkdown: "**You** _(Search)_\n\n/search guided tour\n")
        XCTAssertEqual(turns.first?.pillText, "/search guided tour")
    }

    func testNoTurnsInPlainMarkdown() {
        XCTAssertTrue(ArchivedChat.turns(fromMarkdown: "# Chat\n\nNothing here.").isEmpty)
        XCTAssertTrue(ArchivedChat.turns(fromMarkdown: "**You** said this in bold").isEmpty)
    }
}
