import RTICore
import XCTest

/// Pure prompt assembly and snapshot context for a saved-meeting output: the
/// exact boundaries sent to the model, checked without a provider or a file
/// read.
final class SessionOutputPromptTests: XCTestCase {
    func testPromptHasInstructionContextAndFencedTranscript() {
        let prompt = SessionOutputPrompt.text(
            instruction: "  Write a follow-up.  ",
            context: "session type: Meeting\nworkstream: Northwind",
            transcript: "You: hello there"
        )
        XCTAssertTrue(prompt.hasPrefix("Write a follow-up."), "instruction is trimmed and first")
        XCTAssertTrue(prompt.contains("Session context (from the saved record; a hint only, not proof of attendance):"))
        XCTAssertTrue(prompt.contains("workstream: Northwind"))
        XCTAssertTrue(prompt.contains("Work only from this text. Never invent facts, commitments, or quotes:"))
        XCTAssertTrue(prompt.hasSuffix("You: hello there"), "the transcript is last and verbatim")
    }

    func testPromptOmitsAnEmptyContextBlock() {
        let prompt = SessionOutputPrompt.text(instruction: "Do it", context: "   ", transcript: "T")
        XCTAssertFalse(prompt.contains("Session context"))
        XCTAssertTrue(prompt.hasPrefix("Do it"))
        XCTAssertTrue(prompt.hasSuffix("T"))
    }

    func testPromptDoesNotTrimTheTranscriptBody() {
        let prompt = SessionOutputPrompt.text(instruction: "Do it", context: "", transcript: "  indented\nline  ")
        XCTAssertTrue(prompt.hasSuffix("  indented\nline  "), "the raw transcript is passed through")
    }

    func testStripFrontmatterRemovesOnlyALeadingBlock() {
        let withBlock = "---\noutput: \"x\"\nsource-bytes: 42\n---\n\nBody line\n\nMore"
        XCTAssertEqual(SessionOutputPrompt.stripFrontmatter(withBlock), "Body line\n\nMore")
        XCTAssertEqual(SessionOutputPrompt.stripFrontmatter("No frontmatter here"), "No frontmatter here")
        // A `---` later in the body is not frontmatter: no leading block.
        XCTAssertEqual(SessionOutputPrompt.stripFrontmatter("Body\n---\ntail"), "Body\n---\ntail")
    }

    func testApplyingSpeakerNamesPrefersTheLongestLabel() {
        let text = "`00:01` **remote_1:** hi remote_10\n`00:02` **remote_10:** hi self\n`00:03` **self:** hi"
        let replaced = SessionOutputPrompt.applyingSpeakerNames(
            to: text,
            names: ["remote_1": "Anna", "remote_10": "Bo", "self": "   ", "room_1": "Cara"]
        )
        XCTAssertEqual(replaced, "`00:01` **Anna:** hi remote_10\n`00:02` **Bo:** hi self\n`00:03` **self:** hi", "exact labels change; quoted words and blank names do not")
    }

    func testSpeakerNamesNeverRewriteParticipantWords() {
        let text = "`00:12` **You:** You should ask Speaker 1, not YouTube.\n`00:15` **Speaker 1:** You are right."
        XCTAssertEqual(
            SessionOutputPrompt.applyingSpeakerNames(to: text, names: ["You": "Riley", "Speaker 1": "Morgan"]),
            "`00:12` **Riley:** You should ask Speaker 1, not YouTube.\n`00:15` **Morgan:** You are right."
        )
        XCTAssertEqual(SessionOutputPrompt.applyingSpeakerNames(to: "You should ask Speaker 1.", names: ["You": "Riley"]), "You should ask Speaker 1.")
    }

    func testSnapshotContextIsDeterministicAndSkipsBlanks() {
        let snapshot = SessionOutputSnapshot(
            sessionFolder: "2026-06-08 161305",
            sessionID: "s1",
            mode: "Interview",
            workstream: "Northwind",
            calendarTitle: "  ",
            speakerNames: ["remote_2": "  ", "remote_1": "Anna"]
        )
        XCTAssertEqual(
            snapshot.promptContext,
            "session type: Interview\nworkstream: Northwind\nknown speakers: remote_1 is Anna"
        )
        XCTAssertEqual(SessionOutputSnapshot(sessionFolder: "x").promptContext, "")
    }
}
