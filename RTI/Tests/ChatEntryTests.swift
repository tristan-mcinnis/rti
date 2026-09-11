import RTICore
import XCTest

/// Pins the turn records added to `ChatEntry` for the house thread: every
/// existing call site (which passes none of them) gets empty lists, and the
/// records ride along when given.
final class ChatEntryTests: XCTestCase {
    func test_existingInitialiser_defaultsRecordsToEmpty() {
        let entry = ChatEntry(role: "user", text: "Assist", action: "Assist", contextUsed: true, screenContextUsed: false)

        XCTAssertEqual(entry.referencedPaths, [])
        XCTAssertEqual(entry.attachments, [])
        XCTAssertEqual(entry.tools, [])
        XCTAssertEqual(entry.sources, [])
    }

    func test_recordsAreKeptAndToolsAndSourcesGrowWhileStreaming() {
        let pdf = ChatAttachmentRef(kind: .pdf, name: "Q3 report.pdf", path: "/tmp/Q3 report.pdf", byteCount: 84_000, pageCount: 12, wasCut: true)
        let user = ChatEntry(
            role: "user",
            text: "What changed?",
            action: "Ask",
            contextUsed: false,
            screenContextUsed: false,
            attachments: [pdf]
        )
        XCTAssertEqual(user.attachments, [pdf])

        var answer = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        answer.tools.append(ChatToolLine(kind: .searchVault, text: "Searched vault · 6 results"))
        answer.sources.append(ChatSource(title: "Pricing review", path: "meetings/pricing-review.md"))

        XCTAssertEqual(answer.tools.map(\.kind), [.searchVault])
        XCTAssertEqual(answer.sources.map(\.path), ["meetings/pricing-review.md"])
    }

    func test_screenAttachmentNeverKeepsAPath() {
        let screen = ChatAttachmentRef(kind: .screen, name: "Screen", path: "/tmp/should-not-stay.png")
        XCTAssertNil(screen.path)
    }

    func test_everyKindNamesAGlyph() {
        for kind in ChatAttachmentRef.Kind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has no glyph")
        }
        for kind in ChatToolLine.Kind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has no glyph")
        }
    }
}
