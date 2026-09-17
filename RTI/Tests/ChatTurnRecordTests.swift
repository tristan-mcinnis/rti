import RTICore
import XCTest

/// Pins the records one Assist turn carries (chips over the question,
/// context lines over the answer) and the words the thread prints for them.
final class ChatTurnRecordTests: XCTestCase {
    // MARK: - Chips over the question

    func test_attachments_orderIsMentionsThenFilesThenScreen() {
        let refs = ChatTurnRecordBuilder.attachments(
            mentionPaths: ["projects/northwind/onboarding-brief.md", "projects/northwind/onboarding-brief.md"],
            files: [
                .init(name: "Launch plan.PDF", byteCount: 84_000, pageCount: 12),
                .init(name: "Survey export.txt", byteCount: 48_000, wasCut: true),
            ],
            screenAttached: true
        )
        XCTAssertEqual(refs.map(\.kind), [.vaultFile, .pdf, .text, .screen])
        XCTAssertEqual(refs.map(\.name), ["onboarding-brief.md", "Launch plan.PDF", "Survey export.txt", "Screenshot"])
        XCTAssertEqual(refs.first?.path, "projects/northwind/onboarding-brief.md")
        XCTAssertNil(refs.last?.path, "a screen read keeps no path")
    }

    func test_chipDetail_saysSizePagesAndCut() {
        let pdf = ChatAttachmentRef(kind: .pdf, name: "Q3.pdf", byteCount: 84_000, pageCount: 12)
        XCTAssertEqual(ChatTurnRecordBuilder.chipDetail(for: pdf), "12 pp · 84 KB")
        let text = ChatAttachmentRef(kind: .text, name: "notes.txt", byteCount: 18_400, wasCut: true)
        XCTAssertEqual(ChatTurnRecordBuilder.chipDetail(for: text), "18 KB · cut")
        let cutOnly = ChatAttachmentRef(kind: .text, name: "notes.txt", wasCut: true)
        XCTAssertEqual(ChatTurnRecordBuilder.chipDetail(for: cutOnly), "cut")
        XCTAssertEqual(ChatTurnRecordBuilder.chipDetail(for: ChatAttachmentRef(kind: .screen, name: "Screen")), "once")
        XCTAssertNil(ChatTurnRecordBuilder.chipDetail(for: ChatAttachmentRef(kind: .vaultFile, name: "a.md", path: "a.md")))
    }

    func test_chipAccessibilityLabel_speaksUnits() {
        let pdf = ChatAttachmentRef(kind: .pdf, name: "Q3.pdf", byteCount: 1_200_000, pageCount: 42, wasCut: true)
        XCTAssertEqual(
            ChatTurnRecordBuilder.chipAccessibilityLabel(for: pdf),
            "Attachment: Q3.pdf, PDF, 42 pages, 1.2 megabytes, cut to fit"
        )
    }

    func test_byteText() {
        XCTAssertEqual(ChatTurnRecordBuilder.byteText(900), "900 bytes")
        XCTAssertEqual(ChatTurnRecordBuilder.byteText(84_000), "84 KB")
        XCTAssertEqual(ChatTurnRecordBuilder.byteText(1_200_000), "1.2 MB")
        XCTAssertEqual(ChatTurnRecordBuilder.byteText(24_000_000), "24 MB")
    }

    // MARK: - Lines over the answer

    func test_contextLines_transcriptThenScreen() {
        let lines = ChatTurnRecordBuilder.contextLines(transcriptMinutes: 6, wholeTranscript: false, screenRead: true, screenFromTrail: true)
        XCTAssertEqual(lines, [
            ChatToolLine(kind: .transcript, text: "Used the last 6 min of the transcript"),
            ChatToolLine(kind: .readScreen, text: "Read the screen"),
        ])
    }

    func test_contextLines_trailOnlyAndWholeTranscript() {
        let lines = ChatTurnRecordBuilder.contextLines(transcriptMinutes: 42, wholeTranscript: true, screenRead: false, screenFromTrail: true)
        XCTAssertEqual(lines.map(\.text), ["Used the whole transcript · 42 min", "Used recent screen context"])
        XCTAssertEqual(
            ChatTurnRecordBuilder.contextLines(transcriptMinutes: nil, wholeTranscript: false, screenRead: false, screenFromTrail: false),
            []
        )
    }

    func test_transcriptMinutes_roundsUpAndNeverZero() {
        XCTAssertEqual(ChatTurnRecordBuilder.transcriptMinutes(firstStartMs: 0, lastStartMs: 0), 1)
        XCTAssertEqual(ChatTurnRecordBuilder.transcriptMinutes(firstStartMs: 60_000, lastStartMs: 60_001 + 5 * 60_000), 6)
        XCTAssertEqual(ChatTurnRecordBuilder.transcriptMinutes(firstStartMs: 0, lastStartMs: 15 * 60_000), 15)
    }

    func test_appendingAndMerging_skipRepeats() {
        let screen = ChatToolLine(kind: .readScreen, text: "Read the screen")
        XCTAssertEqual(ChatTurnRecordBuilder.appending(screen, to: [screen]), [screen])
        let a = ChatSource(title: "A", path: "a.md")
        let b = ChatSource(title: "B", path: "b.md")
        XCTAssertEqual(ChatTurnRecordBuilder.merging([b, a], into: [a]).map(\.path), ["a.md", "b.md"])
    }

    // MARK: - The pill

    func test_cannedAction_namesItsGlyph() {
        XCTAssertEqual(ChatTurnRecordBuilder.cannedAction(for: "Assist")?.symbol, "sparkles")
        XCTAssertEqual(ChatTurnRecordBuilder.cannedAction(for: "Recap")?.symbol, "arrow.clockwise")
        XCTAssertEqual(ChatTurnRecordBuilder.cannedAction(for: "Summary")?.symbol, "doc.text")
        XCTAssertEqual(ChatTurnRecordBuilder.cannedAction(for: "Answer latest")?.label, "Answer latest")
        for action in ["Assist", "Answer latest", "Say next", "Follow-ups", "Key tensions", "Probe", "Themes", "Recap", "Quick recap", "Summary"] {
            XCTAssertNotNil(ChatTurnRecordBuilder.cannedAction(for: action), action)
        }
    }

    func test_typedQuestionsAndCommandsAreNotCanned() {
        for action in ["Ask", "Search", "Sources", "Help", "Project"] {
            XCTAssertNil(ChatTurnRecordBuilder.cannedAction(for: action), action)
        }
        XCTAssertNil(ChatTurnRecordBuilder.cannedAction(for: nil))
    }

    func test_pillLabel_recapNamesItsDepth() {
        XCTAssertEqual(ChatTurnRecordBuilder.pillLabel(forAction: "Recap", recapDepth: .brief), "Recap · brief")
        XCTAssertEqual(ChatTurnRecordBuilder.pillLabel(forAction: "Assist", recapDepth: .brief), "Assist")
    }

    // MARK: - Sources

    func test_dayTextAndSourcesText() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
        XCTAssertEqual(ChatTurnRecordBuilder.dayText(for: date, calendar: calendar), "2026-09-04")
        XCTAssertEqual(
            ChatTurnRecordBuilder.sourcesText([ChatSource(title: "A", path: "a.md"), ChatSource(title: "B", path: "b/c.md")]),
            "a.md\nb/c.md"
        )
    }
}
