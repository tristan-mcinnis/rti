import XCTest

final class MarkdownRendererTests: XCTestCase {

    private func inputs(
        title: String? = "Standup",
        summary: String? = nil,
        turns: [MarkdownRenderer.TurnLine] = []
    ) -> MarkdownRenderer.Inputs {
        let start = Date(timeIntervalSince1970: 1_714_656_000)
        return MarkdownRenderer.Inputs(
            id: "session-1",
            startedAt: start,
            endedAt: start.addingTimeInterval(2520), // 42 min
            title: title,
            modeId: nil,
            transcriptQuality: "realtime",
            wavPath: nil,
            attendees: ["Tristan"],
            speakerMap: nil,
            keyTopics: nil,
            summaryMarkdown: summary,
            turns: turns
        )
    }

    func test_make_durationComputed() {
        let entry = MarkdownRenderer.make(inputs())
        XCTAssertEqual(entry.frontmatter.duration, "42m")
    }

    func test_make_durationOver1Hour() {
        let start = Date(timeIntervalSince1970: 1_714_656_000)
        let inp = MarkdownRenderer.Inputs(
            id: "x", startedAt: start, endedAt: start.addingTimeInterval(3900), // 1h 5m
            title: nil, modeId: nil, transcriptQuality: nil, wavPath: nil,
            attendees: nil, speakerMap: nil, keyTopics: nil,
            summaryMarkdown: nil, turns: []
        )
        XCTAssertEqual(MarkdownRenderer.make(inp).frontmatter.duration, "1h 5m")
    }

    func test_make_durationExactHour() {
        let start = Date(timeIntervalSince1970: 1_714_656_000)
        let inp = MarkdownRenderer.Inputs(
            id: "x", startedAt: start, endedAt: start.addingTimeInterval(7200),
            title: nil, modeId: nil, transcriptQuality: nil, wavPath: nil,
            attendees: nil, speakerMap: nil, keyTopics: nil,
            summaryMarkdown: nil, turns: []
        )
        XCTAssertEqual(MarkdownRenderer.make(inp).frontmatter.duration, "2h")
    }

    func test_make_subMinuteSessionRoundsUpTo1m() {
        let start = Date(timeIntervalSince1970: 1_714_656_000)
        let inp = MarkdownRenderer.Inputs(
            id: "x", startedAt: start, endedAt: start.addingTimeInterval(15),
            title: nil, modeId: nil, transcriptQuality: nil, wavPath: nil,
            attendees: nil, speakerMap: nil, keyTopics: nil,
            summaryMarkdown: nil, turns: []
        )
        XCTAssertEqual(MarkdownRenderer.make(inp).frontmatter.duration, "1m")
    }

    func test_renderTranscript_formatsTimestamp() {
        let turns = [
            MarkdownRenderer.TurnLine(speakerId: "self", startMs: 0, text: "hi"),
            MarkdownRenderer.TurnLine(speakerId: "them_1", startMs: 65_000, text: "yo")
        ]
        let body = MarkdownRenderer.renderTranscript(turns)
        XCTAssertTrue(body.contains("[self 0:00] hi"))
        XCTAssertTrue(body.contains("[them_1 1:05] yo"))
    }

    func test_make_includesSummarySection() {
        let entry = MarkdownRenderer.make(inputs(summary: "## Summary\nIt was a meeting."))
        XCTAssertTrue(entry.body.contains("## Summary"))
        XCTAssertTrue(entry.body.contains("It was a meeting."))
    }

    func test_make_summaryWithoutHeading_addsOne() {
        // SummaryController sometimes returns a body without the "## Summary"
        // heading. Renderer should add one so files always have a discoverable
        // section structure.
        let entry = MarkdownRenderer.make(inputs(summary: "It was a meeting."))
        XCTAssertTrue(entry.body.contains("## Summary"))
    }

    func test_make_alwaysAppendsTranscriptHeading() {
        let entry = MarkdownRenderer.make(inputs(turns: []))
        XCTAssertTrue(entry.body.contains("## Transcript"))
    }
}
