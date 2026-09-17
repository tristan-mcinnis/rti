import AppKit
import RTICore
import SwiftUI
import XCTest

/// Package A ("Assist thread") proofs: the house thread in every state the
/// plan names, at the overlay's default width (700) and its minimum (600),
/// in dark and light. PNG prefix `thread-`. The views are fed fixture values
/// directly (`AssistThreadModel`), so no proof reads `LLMController`, the
/// session, credentials, or the vault. Content is invented.
///
/// Also checks the pure pieces behind the thread: find's hit search and
/// Markdown marking, and the transient pasteboard write.
final class AssistThreadRenderProofTests: RenderProofTestCase {
    private static let widths: [CGFloat] = [700, OverlayAppearanceDefaults.widthRange.lowerBound]
    private static let height: CGFloat = 400

    // MARK: - Render proofs

    func testEmpty() throws {
        try renderStates("thread-empty") {
            ProofSurface(model: ThreadFixtures.model(entries: [], emptyHints: ThreadFixtures.readyHints))
        }
    }

    func testMissingKeys() throws {
        try renderStates("thread-missing-keys") {
            ProofSurface(
                model: ThreadFixtures.model(entries: [], emptyHints: ThreadFixtures.missingKeyHints),
                notice: AssistComposerNotice(message: "No API keys yet.", fixTitle: "Open Settings")
            )
        }
    }

    func testSearching() throws {
        let fixture = ThreadFixtures.searching
        try renderStates("thread-searching") {
            ProofSurface(model: fixture)
        }
    }

    func testStreaming() throws {
        try renderStates("thread-streaming") {
            ProofSurface(model: ThreadFixtures.streaming)
        }
    }

    func testAnsweredWithToolsAndSources() throws {
        // Taller, so the sixth source's "1 more" fold is in view.
        try renderStates("thread-answered-tools-sources", height: 560) {
            ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.answeredWithSources))
        }
    }

    func testCannedActionPill() throws {
        try renderStates("thread-canned-action-pill") {
            ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.cannedActions, recapDepth: .brief))
        }
    }

    func testAttachmentsOnPill() throws {
        try renderStates("thread-attachments-on-pill") {
            ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.attachmentsOnPill))
        }
    }

    func testErrorRetry() throws {
        let fixture = ThreadFixtures.errorRetry
        try renderStates("thread-error-retry") {
            ProofSurface(model: fixture)
        }
    }

    func testLatestChip() throws {
        try renderStates("thread-latest-chip") {
            ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.longAnswer), startsFollowingBottom: false)
        }
    }

    func testFind() throws {
        try renderStates("thread-find") {
            let find = ThreadFindState()
            find.open()
            find.query = "tour"
            find.step(1, count: ThreadFindIndex(query: "tour", entries: ThreadFixtures.findTurns, questionText: { $0.text }).hits.count)
            return ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.findTurns), find: find)
        }
    }

    func testCodeBlock() throws {
        try renderStates("thread-code-block") {
            ProofSurface(model: ThreadFixtures.model(entries: ThreadFixtures.codeBlock))
        }
    }

    /// The real adapter (`ResponseView` reading `LLMController`) inside
    /// today's overlay, so the thread's wiring is drawn once end to end.
    /// The header, tabs, and composer around it belong to packages B and C.
    func testThreadInOverlay() throws {
        defer {
            LLMController.shared.seedForRenderProof(entries: [])
            SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        }
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.turnsWithRecords)
        SessionCoordinator.shared.seedForRenderProof(
            entries: [], interim: nil, phase: .recording, startedAt: Date().addingTimeInterval(-761)
        )
        try renderBothAppearances(
            name: "thread-overlay-700",
            size: CGSize(width: 700, height: 440),
            view: OverlayPanelView(modes: ModeStore.inMemory())
        )
    }

    // MARK: - Find checks

    func testFindText_readsWhatTheReaderSees() {
        let markdown = """
        ## The **guided** tour

        - They kept the [tour](https://example.com/tour) out; see `tour.md`.
        > A quote about the tour_plan and 2 * 3.

        ```swift
        let tour = 1
        ```
        | Item | Owner |
        |---|:--|
        | Tour | Speaker 2 |
        """
        let text = MarkdownFindText(markdown).text
        XCTAssertEqual(
            text,
            "The guided tour\nThey kept the tour out; see .\nA quote about the tour_plan and 2 * 3.\n| Item | Owner |\n| Tour | Speaker 2 |"
        )
        XCTAssertFalse(text.contains("example.com"), "a link's target is never matched")
        XCTAssertFalse(text.contains("let tour"), "code is not searched")
    }

    func testFindIndex_countsQuestionsAndAnswersInOrder() {
        let entries = ThreadFixtures.findTurns
        let index = ThreadFindIndex(query: "  TOUR ", entries: entries, questionText: { $0.text })
        XCTAssertEqual(index.hits.map(\.part), [.question, .answer, .answer, .question])
        XCTAssertTrue(index.hits.allSatisfy { (0...1).contains($0.position) })
        XCTAssertTrue(ThreadFindIndex(query: " ", entries: entries, questionText: { $0.text }).hits.isEmpty)
        XCTAssertEqual(ThreadFindIndex(query: "décision", entries: entries, questionText: { $0.text }).hits.count, 1, "accents fold")
    }

    func testFindMarks_wrapHitsForTheFindTheme() {
        let markdown = "They kept the **guided tour** out. See [the tour](https://x.test) and ~~old~~ notes."
        let projection = MarkdownFindText(markdown)
        XCTAssertEqual(projection.text, "They kept the guided tour out. See the tour and old notes.")
        let hits = ThreadFindIndex.ranges(of: "tour", in: projection.text)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(
            projection.marked(hits: hits, current: hits[1]),
            "They kept the **guided ~~tour~~** out. See the [tour](rti-find:current) and old notes."
        )
        // A hit across syntax is marked in pieces, never across a delimiter.
        let across = ThreadFindIndex.ranges(of: "guided tour out", in: projection.text)
        XCTAssertEqual(
            projection.marked(hits: across, current: nil),
            "They kept the **~~guided tour~~** ~~out~~. See the tour and old notes."
        )
    }

    func testFindState_stepsWrapAndSaysTheCount() {
        let find = ThreadFindState()
        XCTAssertFalse(find.close(), "closing a shut bar passes esc on")
        find.open()
        XCTAssertEqual(find.status(count: 3), "")
        find.query = "tour"
        XCTAssertEqual(find.status(count: 0), "No matches")
        XCTAssertEqual(find.status(count: 3), "1 of 3")
        find.step(-1, count: 3)
        XCTAssertEqual(find.status(count: 3), "3 of 3")
        find.step(1, count: 3)
        XCTAssertEqual(find.status(count: 3), "1 of 3")
        find.query = "guided"
        XCTAssertEqual(find.currentIndex(of: 2), 0, "a new query starts at the first hit")
        XCTAssertTrue(find.close())
        XCTAssertEqual(find.query, "")
    }

    // MARK: - Pasteboard

    func testCopyWritesTransientMarkers() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rti-proof-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        NSPasteboard.writeTransient("Lima.", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Lima.")
        let types = try XCTUnwrap(pasteboard.types)
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")))
    }

    // MARK: - Helpers

    /// One state at both widths, both appearances.
    private func renderStates<V: View>(
        _ name: String,
        height: CGFloat = AssistThreadRenderProofTests.height,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ view: () -> V
    ) throws {
        for width in Self.widths {
            try renderBothAppearances(
                name: "\(name)-\(Int(width))",
                size: CGSize(width: width, height: height),
                view: view(),
                file: file,
                line: line
            )
        }
    }
}

// MARK: - Surface

/// The Assist tab's answer area as `ResponseView` lays it out: the find bar
/// when open, the thread, and a notice above where the composer sits. The
/// composer itself is package B's and is not drawn.
private struct ProofSurface: View {
    let model: AssistThreadModel
    var find: ThreadFindState? = nil
    var notice: AssistComposerNotice? = nil
    var startsFollowingBottom = true

    var body: some View {
        let index = find.map { ThreadFindIndex(query: $0.query, entries: model.entries, questionText: model.pillText(for:)) }
        let current = index.flatMap { index in find?.currentIndex(of: index.hits.count).map { index.hits[$0] } }
        VStack(spacing: 0) {
            if let find {
                HouseFindBar(find: find, status: find.status(count: index?.hits.count ?? 0), onNext: {}, onPrevious: {})
                    .padding(.top, House.Spacing.xs)
            }
            AssistThread(
                model: model,
                find: index.map { ThreadFindHighlights(hits: $0.hits, current: current) },
                startsFollowingBottom: startsFollowingBottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if let notice { notice }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)
    }
}

// MARK: - Fixtures

@MainActor
private enum ThreadFixtures {
    static let readyHints = ["⌘↩ runs Assist", "@ adds a vault file", "⌘K for actions"]
    static let missingKeyHints = ["RTI needs a Soniox key to transcribe and a DeepSeek key to answer.", "Keys stay on this Mac."]

    static func model(
        entries: [ChatEntry],
        emptyHints: [String] = [],
        recapDepth: RecapDepth = .standard
    ) -> AssistThreadModel {
        var model = AssistThreadModel()
        model.entries = entries
        model.emptyHints = emptyHints
        model.recapDepth = recapDepth
        return model
    }

    static func user(_ text: String, action: String = "Ask", attachments: [ChatAttachmentRef] = []) -> ChatEntry {
        ChatEntry(role: "user", text: text, action: action, contextUsed: true, screenContextUsed: false, attachments: attachments)
    }

    static func answer(_ text: String, tools: [ChatToolLine] = [], sources: [ChatSource] = []) -> ChatEntry {
        ChatEntry(role: "assistant", text: text, action: nil, contextUsed: false, screenContextUsed: false, tools: tools, sources: sources)
    }

    static let transcriptLine = ChatToolLine(kind: .transcript, text: "Used the last 6 min of the transcript")

    // Searching: the question at once, the search line under it.
    static var searching: AssistThreadModel {
        let question = user("What did we decide about the guided tour last time?")
        let placeholder = answer("Searching the vault…")
        var model = model(entries: [question, placeholder])
        model.progress = [placeholder.id: "Searching the vault…"]
        model.streamingID = placeholder.id
        return model
    }

    // Streaming: the lines so far and live prose with a caret.
    static var streaming: AssistThreadModel {
        let earlier = user("Who owns the decision note?")
        let earlierAnswer = answer("Speaker 2 does. They said they would send it before Thursday so design is not surprised.", tools: [transcriptLine])
        let assist = user(PromptFixtures.assistPrompt, action: "Assist")
        let live = answer(
            "They've just agreed to drop the guided tour and measure first-screen drop-off instead. Worth raising now: who sets the",
            tools: [transcriptLine, ChatToolLine(kind: .searchVault, text: "Searched this project · 4 results")]
        )
        var model = model(entries: [earlier, earlierAnswer, assist, live])
        model.streamingID = live.id
        return model
    }

    // Answered: tool lines above, prose, six sources (five shown, one more).
    static var answeredWithSources: [ChatEntry] {
        [
            user("What did we decide about the guided tour last time?"),
            answer(
                """
                Last week the team kept the guided tour **out of the first release**. It comes back only if first-screen drop-off passes the threshold Speaker 2 agreed to set.

                Two things are still open:

                - Who sets the threshold, and by when.
                - Whether design hears about it before Thursday.
                """,
                tools: [
                    transcriptLine,
                    ChatToolLine(kind: .searchVault, text: "Searched vault · 6 results"),
                    ChatToolLine(kind: .readDocument, text: "Read Onboarding brief"),
                ],
                sources: [
                    ChatSource(title: "Onboarding Scope Review with Northwind", path: "projects/personal/rti/sessions/2026-09-05 150000/summary.md", date: RenderFixtures.fixedDay(-7)),
                    ChatSource(title: "Onboarding brief", path: "projects/northwind/onboarding-brief.md", date: RenderFixtures.fixedDay(-9)),
                    ChatSource(title: "Quarterly planning sync", path: "meetings/20260901-quarterly-planning.md", date: RenderFixtures.fixedDay(-11)),
                    ChatSource(title: "Pricing page teardown", path: "projects/northwind/pricing-teardown.md", date: RenderFixtures.fixedDay(-12)),
                    ChatSource(title: "projects/northwind/research/first-screen-drop-off-analysis-with-a-long-name.md", path: "projects/northwind/research/first-screen-drop-off-analysis-with-a-long-name.md", date: RenderFixtures.fixedDay(-14)),
                    ChatSource(title: "Design review notes", path: "projects/northwind/design-review.md", date: RenderFixtures.fixedDay(-20)),
                ]
            ),
        ]
    }

    // Canned actions: the pill names the action and its glyph, never the prompt.
    static var cannedActions: [ChatEntry] {
        [
            user(PromptFixtures.recapPrompt, action: "Recap"),
            answer(
                """
                - Guided tour is out of the first release.
                - Speaker 2 owns the decision note, due Thursday.
                """,
                tools: [transcriptLine]
            ),
            user(PromptFixtures.assistPrompt, action: "Assist"),
            answer(
                "Ask who sets the drop-off threshold that would bring the tour back, and by when. That decides whether \"point-one\" is a real commitment.",
                tools: [transcriptLine, ChatToolLine(kind: .readScreen, text: "Used recent screen context")]
            ),
        ]
    }

    // Attachments over a long question that collapses.
    static var attachmentsOnPill: [ChatEntry] {
        let long = Array(repeating: "Compare the launch plan with the survey export and tell me where the first-screen numbers disagree with what Speaker 2 said in the meeting today, and whether the onboarding brief already covers it.", count: 8)
            .joined(separator: " ")
        return [
            user(long, attachments: [
                ChatAttachmentRef(kind: .vaultFile, name: "onboarding-brief.md", path: "projects/northwind/onboarding-brief.md"),
                ChatAttachmentRef(kind: .pdf, name: "Launch plan.pdf", path: "/tmp/Launch plan.pdf", byteCount: 84_000, pageCount: 12),
                ChatAttachmentRef(kind: .text, name: "Survey export with a very long file name from the research team.txt", path: "/tmp/Survey export.txt", byteCount: 48_000, wasCut: true),
                ChatAttachmentRef(kind: .screen, name: "Screen"),
            ]),
            answer(
                "The survey puts first-screen drop-off at 38%; the launch plan assumes 25%. Speaker 2 quoted the plan's number, so the gap is not in the brief yet.",
                tools: [transcriptLine, ChatToolLine(kind: .readScreen, text: "Read the screen")]
            ),
        ]
    }

    // Error: the failed question keeps its pill, the error line sits under it.
    static var errorRetry: AssistThreadModel {
        let failed = user("And what did pricing decide?")
        var model = model(entries: [
            user("What did we decide about the guided tour?"),
            answer("It stays out of the first release.", tools: [transcriptLine]),
            failed,
        ])
        model.turnError = .init(questionID: failed.id, message: "DeepSeek is busy (503). Try again in a moment.")
        return model
    }

    // A long answer, scrolled up from the bottom.
    static var longAnswer: [ChatEntry] {
        let steps = (1...24).map { "\($0). Step \($0) of the launch plan: build, test, and write the note." }.joined(separator: "\n")
        return [user("Walk me through the launch plan"), answer(steps)]
    }

    // Find: hits in a question and an answer, one of them current.
    static var findTurns: [ChatEntry] {
        [
            user("What did we decide about the guided tour?"),
            answer(
                "The team kept the **guided tour** out of the first release. The tour comes back only if first-screen drop-off passes the threshold. The décision note is due Thursday.",
                tools: [transcriptLine]
            ),
            user("Who tells design about the tour?"),
        ]
    }

    // A code block with its header strip.
    static var codeBlock: [ChatEntry] {
        [
            user("How do I export the transcript as plain text?"),
            answer(
                """
                Run this from the session folder:

                ```sh
                rti-export --format txt --out ~/Desktop/northwind-transcript.txt "2026-09-05 150000"
                ```

                The file keeps speaker names and timestamps.
                """
            ),
        ]
    }
}

/// Stand-ins for the long internal prompts canned actions send. The pill
/// must never show them.
private enum PromptFixtures {
    static let assistPrompt = "You are assisting me live in a meeting. Using the transcript, suggest the single most useful thing I could say next, in one or two sentences."
    static let recapPrompt = "Recap the meeting so far as bullets. Keep it brief: one or two bullets."
}
