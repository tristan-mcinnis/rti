import XCTest

final class CorpusWriterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-corpus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeEntry() -> CorpusEntry {
        CorpusEntry(
            frontmatter: CorpusEntry.Frontmatter(
                id: "abc-123",
                date: Date(timeIntervalSince1970: 1_714_656_000),
                capturedAt: nil, duration: nil, title: "Test",
                mode: nil, attendees: nil, speakerMap: nil,
                keyTopics: nil, transcriptQuality: nil, wavPath: nil
            ),
            body: "## Summary\nA test."
        )
    }

    func test_write_createsFile() throws {
        let url = try CorpusWriter.write(makeEntry(), to: tmpDir, slug: "test-meeting")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_write_filenameIncludesDateAndSlug() throws {
        let url = try CorpusWriter.write(makeEntry(), to: tmpDir, slug: "pricing-talk")
        XCTAssertTrue(url.lastPathComponent.contains("pricing-talk"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
    }

    func test_write_collisionAppendsSuffix() throws {
        let entry = makeEntry()
        let first = try CorpusWriter.write(entry, to: tmpDir, slug: "same-slug")
        let second = try CorpusWriter.write(entry, to: tmpDir, slug: "same-slug")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.lastPathComponent.contains("same-slug-1"))
    }

    func test_write_contentRoundTrips() throws {
        let entry = makeEntry()
        let url = try CorpusWriter.write(entry, to: tmpDir, slug: "rt")
        let parsed = try CorpusReader.read(url)
        XCTAssertEqual(parsed.frontmatter.id, entry.frontmatter.id)
        XCTAssertEqual(parsed.body, entry.body)
    }

    func test_slug_fromTitle_kebabCases() {
        XCTAssertEqual(CorpusWriter.slug(forTitle: "Pricing Discussion: Round 2"), "pricing-discussion-round-2")
    }

    func test_slug_fromEmpty_fallsBackToTimestamp() {
        let slug = CorpusWriter.slug(forTitle: nil)
        XCTAssertTrue(slug.hasPrefix("meeting-"))
    }

    func test_slug_capsAt40Chars() {
        let long = String(repeating: "abcdef ", count: 20)
        XCTAssertLessThanOrEqual(CorpusWriter.slug(forTitle: long).count, 40)
    }
}
