import RTICore
import XCTest

@MainActor
final class GuideSourceImportTests: RenderProofTestCase {
    func testWordGuideLoadsFromProjectWithoutPreparingJSON() async throws {
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: ExternalTools.workbookGuideParser.path), "Requires the installed synthesis workbook parser.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("06-discussion-guide")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/GuideFixtures/cup-guide.docx")
        let word = folder.appendingPathComponent("Moderator’s cup guide.docx")
        try FileManager.default.copyItem(at: fixture, to: word)
        let loaded = try await GuideFileReader.shared.loadGuide(at: root)
        XCTAssertEqual(loaded.sourceURL.standardizedFileURL, word.standardizedFileURL)
        XCTAssertEqual(loaded.document.sections.count, 2)
        XCTAssertEqual(loaded.document.questions.map(\.qid), ["S1Q1", "S2Q1"])
        XCTAssertEqual(loaded.document.questions.first?.zh, "你会选哪个杯子？")
        let bytes = try XCTUnwrap(loaded.parsedSourceJSON)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNotNil(metadata["frontmatter"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dg-questions.json").path))

        try bytes.write(to: folder.appendingPathComponent("dg-questions.json"))
        do {
            _ = try await GuideFileReader.shared.loadGuide(at: root)
            XCTFail("A prepared JSON beside an editable Word guide should offer the version picker.")
        } catch GuideFileReader.ReadError.severalGuides {}
    }

    func testProjectStatusAloneIsNotAGuide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("## Status\n1. Initial steps".utf8).write(to: root.appendingPathComponent("00-status.md"))
        do {
            _ = try await GuideFileReader.shared.loadGuide(at: root)
            XCTFail("Project background must not be loaded as a guide.")
        } catch GuideFileReader.ReadError.noGuide {}
    }
}
