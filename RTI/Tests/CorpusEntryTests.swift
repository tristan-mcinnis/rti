import XCTest

final class CorpusEntryTests: XCTestCase {

    private func sampleFrontmatter(id: String = "abc-123") -> CorpusEntry.Frontmatter {
        CorpusEntry.Frontmatter(
            id: id,
            date: Date(timeIntervalSince1970: 1_714_656_000), // fixed for stable output
            capturedAt: Date(timeIntervalSince1970: 1_714_656_000),
            duration: "42m",
            title: "Pricing discussion",
            mode: "sales",
            attendees: ["Tristan", "Alex"],
            speakerMap: [
                "self": .init(name: "Tristan", source: "deterministic"),
                "them_1": .init(name: "Alex", source: "llm")
            ],
            keyTopics: ["pricing", "billing"],
            transcriptQuality: "realtime",
            wavPath: "/tmp/foo.wav"
        )
    }

    func test_render_startsWithFrontmatterDelimiter() throws {
        let entry = CorpusEntry(frontmatter: sampleFrontmatter(), body: "## Summary\nGood")
        let rendered = try entry.render()
        XCTAssertTrue(rendered.hasPrefix("---\n"))
    }

    func test_render_includesBody() throws {
        let entry = CorpusEntry(frontmatter: sampleFrontmatter(), body: "## Summary\nHello")
        let rendered = try entry.render()
        XCTAssertTrue(rendered.contains("## Summary"))
        XCTAssertTrue(rendered.contains("Hello"))
    }

    func test_roundTrip_preservesFrontmatter() throws {
        let entry = CorpusEntry(frontmatter: sampleFrontmatter(), body: "## Summary\nGood meeting")
        let rendered = try entry.render()
        let parsed = try CorpusEntry.parse(rendered)
        XCTAssertEqual(parsed.frontmatter.id, entry.frontmatter.id)
        XCTAssertEqual(parsed.frontmatter.title, entry.frontmatter.title)
        XCTAssertEqual(parsed.frontmatter.attendees, entry.frontmatter.attendees)
        XCTAssertEqual(parsed.frontmatter.keyTopics, entry.frontmatter.keyTopics)
        XCTAssertEqual(parsed.frontmatter.speakerMap, entry.frontmatter.speakerMap)
    }

    func test_roundTrip_preservesBody() throws {
        let body = "## Summary\nA two-line\nsummary.\n\n## Transcript\n[self 0:00] hi"
        let entry = CorpusEntry(frontmatter: sampleFrontmatter(), body: body)
        let rendered = try entry.render()
        let parsed = try CorpusEntry.parse(rendered)
        XCTAssertEqual(parsed.body, body)
    }

    func test_parse_throwsOnMissingFrontmatter() {
        XCTAssertThrowsError(try CorpusEntry.parse("no frontmatter here"))
    }

    func test_parse_throwsOnUnterminatedFrontmatter() {
        XCTAssertThrowsError(try CorpusEntry.parse("---\nid: x\n# never closed"))
    }
}
