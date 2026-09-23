import AppKit
import HouseChatCore
import RTICore
import SwiftUI
import XCTest

/// Package B ("composer") proofs: the overlay composer in every state the
/// house grammar names (chat-surfaces.md sections 3 and 4), drawn under a
/// small invented thread so the floating layers show what they cover.
/// PNG prefix `composer-`. The fixture vault is installed by the harness;
/// no proof reads the real vault or real meetings.
final class ComposerRenderProofTests: RenderProofTestCase {
    private static let wide = CGSize(width: 700, height: 440)
    private static let narrow = CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440)

    private var savedPrimaryActionID = ""

    override func setUp() async throws {
        try await super.setUp()
        let llm = LLMController.shared
        savedPrimaryActionID = llm.primaryActionID
        llm.primaryActionID = "assist"
        llm.seedForRenderProof(entries: [])
        llm.clearPendingScreenContext()
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        OverlayInputState.shared.mode = .chat
    }

    override func tearDown() async throws {
        let llm = LLMController.shared
        llm.primaryActionID = savedPrimaryActionID
        llm.clearPendingScreenContext()
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        OverlayInputState.shared.mode = .chat
        try await super.tearDown()
    }
    private func recording() {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: Date().addingTimeInterval(-761)
        )
    }

    private func render(_ name: String, seed: ComposerRenderSeed = ComposerRenderSeed(), size: CGSize = wide, thread: Bool = true) throws {
        try renderBothAppearances(name: name, size: size, view: ComposerProofHost(seed: seed, showsThread: thread))
    }

    // MARK: - Empty

    func testEmptyIdle() throws {
        try render("composer-empty-idle", thread: false)
        try render("composer-empty-idle-600", size: Self.narrow, thread: false)
    }

    func testEmptyRecording() throws {
        recording()
        try render("composer-empty-recording", thread: false)
    }

    // MARK: - Typing

    func testTyped() throws {
        try render("composer-typed", seed: ComposerRenderSeed(draft: "What did we decide about the guided tour?"))
    }

    func testMultiline() throws {
        let draft = """
        Draft the decision note for design:
        1. Ship without the guided tour.
        2. Measure first-screen drop-off for two weeks.
        3. Bring the tour back in point-one only if drop-off passes the threshold.
        """
        try render("composer-multiline", seed: ComposerRenderSeed(draft: draft))
    }

    func testPaletteAndAttachStayAboveALongDraft() throws {
        CommandRegistry.shared.replaceAll(RenderFixtures.commands)
        let draft = Array(repeating: "Review the synthetic session notes before drafting a response.", count: 10).joined(separator: "\n")
        try render("composer-long-palette", seed: ComposerRenderSeed(draft: draft, layer: .palette))
        let minimumContentHeight = CGFloat(OverlayAppearanceDefaults.heightRange.lowerBound)
            - House.Control.input - House.Control.railRow - House.Spacing.xs
        try render("composer-long-palette-minimum", seed: ComposerRenderSeed(draft: draft, layer: .palette),
                   size: CGSize(width: Self.narrow.width, height: minimumContentHeight))
        try render("composer-long-attach", seed: ComposerRenderSeed(draft: draft, layer: .addContext), size: Self.narrow)
        let oneLine = HouseComposerMetrics.rowHeight(fieldHeight: HouseComposerMetrics.lineHeight(fontSize: 13), fontSize: 13)
        let houseMax = HouseComposerMetrics.rowHeight(fieldHeight: 8 * HouseComposerMetrics.lineHeight(fontSize: 13), fontSize: 13)
        XCTAssertGreaterThan(houseMax, oneLine)
        // The chrome above the field shares this budget with the palette drawn
        // over it. Since the source and route bar was deleted (2026-09-23) the
        // field reaches the house's eight lines even at this height, so what is
        // guarded here is the house cap and that the palette still fits beneath
        // it; the line give-back is guarded at a genuinely short height in
        // `testFieldLineBudgetGivesBackLinesOnlyWhenShort`.
        let capped = ComposerFieldBudget.maxHeight(availableHeight: minimumContentHeight, fontSize: 13)
        XCTAssertLessThanOrEqual(capped, 8 * HouseComposerMetrics.lineHeight(fontSize: 13),
                                 "the field never exceeds the house's eight lines")
        XCTAssertGreaterThanOrEqual(capped, HouseComposerMetrics.lineHeight(fontSize: 13))
        let long = HouseComposerMetrics.rowHeight(fieldHeight: capped, fontSize: 13)
        let rowLimit = HouseComposerMetrics.paletteRows(availableHeight: minimumContentHeight, composerHeight: long)
        let palette = CommandPaletteView(query: .constant(""), onRun: { _ in },
                                         leadingCommands: RenderFixtures.commands, maxVisibleRows: rowLimit)
            .frame(width: HouseChatMetrics.paletteWidth)
        let host = NSHostingView(rootView: palette)
        XCTAssertLessThanOrEqual(host.fittingSize.height + long, minimumContentHeight,
                                "Search, commands, footer and the full composer must fit at minimum window height")
    }

    func testFailedAttachmentKeepsDraftAndShowsBlockedAction() throws {
        let document = ComposerDocument(name: "Synthetic notes.txt", phase: .failed("Could not be read"))
        try render("composer-failed-keeps-draft", seed: ComposerRenderSeed(draft: "Review these notes", documents: [document]))
    }

    func testDocumentIdentityUsesFullPathInsteadOfBasename() {
        let a = URL(fileURLWithPath: "/tmp/rti-fixture-one/notes.txt")
        let b = URL(fileURLWithPath: "/tmp/rti-fixture-two/notes.txt")
        let document = ComposerDocument(name: "notes.txt", phase: .reading, sourceURL: a)
        XCTAssertTrue(document.isSameSource(as: a))
        XCTAssertFalse(document.isSameSource(as: b))
    }

    func testComposerPaletteFuzzyMatchesHostedAndRegistryCommands() {
        let hosted = RTICommand(id: "composer.attach", title: "Attach…", keywords: ["document"], perform: {})
        let registry = RTICommand(id: "session.record", title: "Record Session", perform: {})
        XCTAssertEqual(CommandPaletteView.entries(query: "ATCH", leading: [hosted], registry: [registry]).map(\.id), [hosted.id])
        XCTAssertEqual(CommandPaletteView.entries(query: "rcdssn", leading: [hosted], registry: [registry]).map(\.id), [registry.id])
    }

    // MARK: - Streaming

    func testStreamingStop() throws {
        recording()
        try render("composer-streaming-stop", seed: ComposerRenderSeed(isStreaming: true))
    }

    func testQueued() throws {
        recording()
        try render(
            "composer-queued",
            seed: ComposerRenderSeed(draft: "And who owns the decision note?", isStreaming: true, isQueued: true)
        )
    }

    // MARK: - Note mode

    func testNoteModeLive() throws {
        recording()
        OverlayInputState.shared.mode = .liveNote
        try render("composer-note-mode-live", thread: false)
    }

    func testNoteModePrep() throws {
        OverlayInputState.shared.mode = .liveNote
        try render("composer-note-mode-prep", seed: ComposerRenderSeed(draft: "Ask about the pricing threshold"), thread: false)
    }

    // MARK: - Strip

    func testStripStates() throws {
        LLMController.shared.attachScreenContext("Invented screen text for the proof.")
        let seed = ComposerRenderSeed(
            draft: "Which numbers differ between these?",
            mentionPaths: ["projects/northwind/onboarding-brief.md"],
            documents: Self.stripDocuments,
            focusedChipID: nil
        )
        try render("composer-strip-states", seed: seed)
        try render("composer-strip-states-600", seed: seed, size: Self.narrow)
        // Wide enough that no chip scrolls away: every phase in one row.
        try render("composer-strip-states-wide", seed: seed, size: CGSize(width: 1_440, height: 160), thread: false)
    }

    func testStripKeyboardSelection() throws {
        let documents = Self.stripDocuments
        let seed = ComposerRenderSeed(documents: documents, focusedChipID: documents[1].id.uuidString)
        try render("composer-strip-selected", seed: seed, thread: false)
    }

    // MARK: - Layers

    func testAddContext() throws {
        recording()
        try render("composer-add-context", seed: ComposerRenderSeed(layer: .addContext))
    }

    func testSearchScope() throws {
        try render("composer-search-scope", seed: ComposerRenderSeed(layer: .searchScope, chooserIndex: 1))
    }

    func testMentionChooser() throws {
        let seed = ComposerRenderSeed(
            draft: "Summarize @onb",
            mentionCandidates: [
                "projects/northwind/onboarding-brief.md",
                "projects/northwind/onboarding-metrics.md",
                "meetings/20260904-onboarding-scope-review.md",
                "projects/personal/rti/sessions/2026-09-05 150000/notes.md",
            ],
            chooserIndex: 0
        )
        try render("composer-mention-chooser", seed: seed)
    }

    func testSlashChooser() throws {
        try render("composer-slash-chooser", seed: ComposerRenderSeed(draft: "/re", chooserIndex: 1))
    }

    func testPalette() throws {
        CommandRegistry.shared.replaceAll(RenderFixtures.commands)
        try render("composer-palette", seed: ComposerRenderSeed(layer: .palette))
        try render("composer-palette-600", seed: ComposerRenderSeed(layer: .palette), size: Self.narrow)
    }

    func testDrop() throws {
        try render("composer-drop", seed: ComposerRenderSeed(draft: "Compare these two", isDropTargeted: true))
    }

    /// An error that belongs to no turn, with its fix-it, over the row.
    func testErrorWithFix() throws {
        let view = VStack(spacing: 0) {
            Spacer(minLength: 0)
            HouseComposer(
                action: ComposerAction(kind: .runPrimary, label: "Assist", keys: ["⌘", "↩"]),
                placeholder: ComposerState.idlePlaceholder,
                showsPlaceholder: true,
                error: ComposerErrorLine(message: "The DeepSeek key was refused. Check it in Settings.", fixTitle: "Open Settings")
            ) {
                Color.clear.frame(height: HouseComposerMetrics.lineHeight(fontSize: House.TypeToken.Size.bodySmall))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)
        try renderBothAppearances(name: "composer-error", size: CGSize(width: 700, height: 160), view: view)
    }

    // MARK: - Source and route bar

    /// The two choices the next Send is made of: which evidence, and where it
    /// goes. Drawn at the default width, at the minimum width, and widened.
    /// The attached/broader choice now lives in the Add Context pane: the
    /// composer's source and route bar was deleted on 2026-09-23 because it
    /// repeated the model the header already names and the chips read as noise.
    ///
    /// The two modes must render differently. They did not the first time: the
    /// row sat sixth of seven, below the pane's five-row fold at this size, so
    /// the proof wrote two identical PNGs and proved nothing. This assertion is
    /// what keeps the row inside the fold at the height the overlay opens at.
    func testSourceModeLivesInAddContext() throws {
        try render("composer-add-context-search-off", seed: ComposerRenderSeed(layer: .addContext), thread: false)
        try render(
            "composer-add-context-search-on",
            seed: ComposerRenderSeed(layer: .addContext, isBroaderSearch: true),
            thread: false
        )
        let off = try RenderProofHarness.render(
            ComposerProofHost(seed: ComposerRenderSeed(layer: .addContext), showsThread: false),
            size: Self.wide,
            appearance: .darkAqua
        )
        let on = try RenderProofHarness.render(
            ComposerProofHost(
                seed: ComposerRenderSeed(layer: .addContext, isBroaderSearch: true),
                showsThread: false
            ),
            size: Self.wide,
            appearance: .darkAqua
        )
        XCTAssertNotEqual(off, on, "the off and on rows must both be visible at the overlay's own size")
    }

    /// A pending screenshot names its destination before Send, and a text-only
    /// route says the image stays on this Mac instead.
    func testImageRouteLabels() throws {
        let cloud = ComposerRoutePreview(
            label: "DeepSeek · deepseek-chat · Fast",
            imageRouteLabel: "Images go to DeepSeek (cloud)"
        )
        try render("composer-image-route", seed: ComposerRenderSeed(draft: "Read this chart", pendingImage: true, route: cloud))
        let local = ComposerRoutePreview(
            label: "Local Models · local-chat · Fast",
            imageRouteLabel: "Images stay on this Mac; text only"
        )
        try render(
            "composer-image-route-local",
            seed: ComposerRenderSeed(draft: "Read this chart", pendingImage: true, route: local),
            thread: false
        )
    }

    /// A route that cannot run names the fix instead of describing itself.
    func testBlockedRouteNamesTheFix() throws {
        let blocked = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "openai"),
            provider: LLMProviderConfig(
                id: "openai",
                displayName: "OpenAI",
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "gpt-5",
                supportsThinking: true,
                apiKey: { "" }
            ),
            imageCount: 0,
            chosenLabel: "OpenAI · gpt-5 · Fast"
        )
        try render("composer-route-blocked", seed: ComposerRenderSeed(draft: "Draft a reply", route: blocked), thread: false)
    }

    /// No vault configured: chat works, and the composer says nothing is saved.
    func testNoVaultSaysNothingIsSaved() throws {
        try render(
            "composer-not-saved",
            seed: ComposerRenderSeed(draft: "Remember this for the debrief", savesToVault: false),
            thread: false
        )
    }

    /// A cut read is named with its own file and the extractor's line.
    func testCutSourceIsNamed() throws {
        let document = ComposerDocument(name: "Board pack.pdf", phase: .ready(Self.attachment(
            name: "Board pack.pdf",
            path: "/tmp/Board pack.pdf",
            kind: .pdf,
            byteCount: 4_200_000,
            pageCount: 212,
            wasCut: true,
            limitSummary: "200,000 characters kept"
        )))
        try render(
            "composer-source-cut",
            seed: ComposerRenderSeed(draft: "Summarize the board pack", documents: [document]),
            thread: false
        )
    }

    /// The controller's own notices about retrieval and about a saved source it
    /// can no longer rehydrate, in the composer's words rather than a claim of
    /// its own.
    func testRetrievalAndRetainedNotices() throws {
        try render(
            "composer-retrieval-degraded",
            seed: ComposerRenderSeed(
                draft: "What else did Northwind say about onboarding?",
                isBroaderSearch: true,
                retrievalNotice: "Vault search fell back to the keyword scan: the index timed out"
            ),
            thread: false
        )
        try render(
            "composer-retained-missing",
            seed: ComposerRenderSeed(
                draft: "Follow up on that",
                retainedNotice: "Some saved sources are no longer readable from this chat's store (launch-plan.pdf). They are not refetched; the answer uses what was kept."
            ),
            thread: false
        )
    }

    /// An unknown slash command stays local: the field offers the explicit
    /// Send as Text action and no key that would send it by accident.
    func testUnknownSlashCommandStaysLocal() throws {
        try render("composer-unknown-command", seed: ComposerRenderSeed(draft: "/deploy now"), thread: false)
    }

    /// One searchable chooser for `@` and `+`: the vault files the mention
    /// index matched, RTI's recent meetings, its projects and clients, and the
    /// composer's own actions, in one ranked list.
    func testUnifiedMentionChooserSearchesProjectsAndMeetings() throws {
        let rows = [
            AddContextRow(kind: .vaultFile, symbol: "doc.text", title: "onboarding-brief.md",
                          detail: "projects/northwind"),
            AddContextRow(kind: .vaultFile, symbol: "waveform", title: "Onboarding walkthrough",
                          detail: "2026-09-02 · session"),
            AddContextRow(kind: .vaultFile, symbol: "calendar", title: "Onboarding scope review",
                          detail: "2026-09-04 · meeting"),
            AddContextRow(kind: .scope(id: "northwind"), symbol: "folder", title: "Northwind app",
                          detail: "Project", isCurrent: true),
            AddContextRow(kind: .attachFile, symbol: "paperclip", title: "Attach File…",
                          detail: "PDF, Markdown, text, or an image, for the next question"),
        ]
        let seed = ComposerRenderSeed(draft: "Summarize @onb", mentionRows: rows, chooserIndex: 2)
        try render("composer-mention-unified", seed: seed)
        try render("composer-mention-unified-600", seed: seed, size: Self.narrow)
    }

    /// A dated log handed over from the Chats library: the chip names the
    /// source that already grounds the next turn, and the Add Context preview
    /// names it too, so a grounded request never reads as a request with no
    /// source.
    func testDatedSourceChip() throws {
        try render(
            "composer-dated-source",
            seed: ComposerRenderSeed(
                draft: "What did I record about the pricing threshold?",
                pendingDatedSourceName: "Dated log 2026-09-12"
            ),
            thread: false
        )
        try render(
            "composer-dated-source-600",
            seed: ComposerRenderSeed(
                draft: "What did I record about the pricing threshold?",
                pendingDatedSourceName: "Dated log 2026-09-12"
            ),
            size: Self.narrow,
            thread: false
        )
        try render(
            "composer-dated-source-attach",
            seed: ComposerRenderSeed(layer: .addContext, pendingDatedSourceName: "Dated log 2026-09-12"),
            size: Self.narrow,
            thread: false
        )
    }

    // MARK: - Checks

    /// The field's own line budget: the house's eight whenever there is room,
    /// fewer lines in a short window, and never fewer than one.
    func testFieldLineBudgetGivesBackLinesOnlyWhenShort() {
        XCTAssertEqual(
            ComposerFieldBudget.maxLines(availableHeight: 900, fontSize: 13),
            HouseComposerMetrics.maxLines
        )
        XCTAssertEqual(
            ComposerFieldBudget.maxLines(availableHeight: 0, fontSize: 13),
            HouseComposerMetrics.maxLines,
            "an unmeasured height asks for no change"
        )
        // The source and route bar's 36 pt left this budget on 2026-09-23, so
        // the overlay's own minimum height no longer forces a reduction: the
        // field uses all eight lines there. A window 60 pt shorter than that
        // still has to give lines back, or the palette's own search row goes
        // off the top of the panel.
        let minimum = CGFloat(OverlayAppearanceDefaults.heightRange.lowerBound)
            - House.Control.input - House.Control.railRow - House.Spacing.xs
        XCTAssertEqual(
            ComposerFieldBudget.maxLines(availableHeight: minimum, fontSize: 13),
            HouseComposerMetrics.maxLines,
            "at the overlay's minimum height the field now takes the house's eight"
        )
        let tight = ComposerFieldBudget.maxLines(availableHeight: minimum - 60, fontSize: 13)
        XCTAssertGreaterThanOrEqual(tight, 1)
        XCTAssertLessThan(tight, HouseComposerMetrics.maxLines)

        // At the overlay's floor (`minimum`: the window minimum less the
        // panel's header and tab row, the quantity the composer is handed) the
        // bar's removal leaves the field the house's eight lines when nothing
        // else is pending...
        XCTAssertEqual(
            ComposerFieldBudget.maxLines(availableHeight: minimum, fontSize: 13),
            HouseComposerMetrics.maxLines
        )
        // ...but a dated-source chip row above the field still costs it lines.
        // The give-back is therefore a live path, not a guard for windows the
        // app cannot produce. Corrected 2026-09-23: the first version of these
        // two assertions measured `heightRange.lowerBound - Spacing.xs` (392),
        // which omits the panel's header and tab row, so it passed while
        // stating the opposite of the truth.
        let withChip = ComposerFieldBudget.maxLines(
            availableHeight: minimum,
            fontSize: 13,
            extraChrome: AssistantInputView.datedSourceChipRowHeight
        )
        XCTAssertGreaterThanOrEqual(withChip, 1)
        XCTAssertLessThan(withChip, HouseComposerMetrics.maxLines)
    }

    /// The palette puts the mode's quick actions first and never shows the
    /// registry's note and screen rows twice.
    func testPaletteEntriesDedupeTheRegistry() {
        let leading = [
            RTICommand(id: "chat.assist", title: "Assist", subtitle: "⌘↩", perform: {}),
            RTICommand(id: "composer.note", title: "Note Mode", subtitle: "⌘⌥N", perform: {}),
        ]
        let registry = [
            RTICommand(id: "chat.assist", title: "Assist (what to do next)", perform: {}),
            RTICommand(id: "note.toggle", title: "Toggle Note Entry", perform: {}),
            RTICommand(id: "session.start", title: "Start Recording", subtitle: "⌘⇧R", perform: {}),
        ]
        let rows = CommandPaletteView.entries(query: "", leading: leading, registry: registry, hiding: ["note.toggle"])
        XCTAssertEqual(rows.map(\.id), ["chat.assist", "composer.note", "session.start"])

        let filtered = CommandPaletteView.entries(query: "record", leading: leading, registry: [registry[2]])
        XCTAssertEqual(filtered.map(\.id), ["session.start"])
    }

    func testPaletteWordsForRegistryRows() {
        let parented = RTICommand(id: "primary.set.recap", title: "Recap", perform: {}, menuParent: "Set ⌘⏎ to")
        XCTAssertEqual(CommandPaletteView.displayTitle(for: parented), "Set ⌘⏎ to: Recap")
        let typedHint = RTICommand(id: "overlay.toggle", title: "Show RTI  ⌘\\", subtitle: "⌘\\", perform: {})
        XCTAssertEqual(CommandPaletteView.displayTitle(for: typedHint), "Show RTI")
        XCTAssertEqual(CommandPaletteView.keyCaps(for: typedHint), ["⌘", "\\"])
        XCTAssertEqual(CommandPaletteView.keyCaps(for: RTICommand(id: "chat.primary", title: "P", subtitle: "⌘⏎", perform: {})), ["⌘", "↩"])
        XCTAssertEqual(CommandPaletteView.group(for: RTICommand(id: "session.pause", title: "Pause", perform: {})), "Session")
        XCTAssertEqual(CommandPaletteView.group(for: RTICommand(id: "chat.recap", title: "Recap", perform: {})), "Quick action")
    }

    /// Documents keep the 512 KB and 24,000-character limits, and the chip
    /// now says when the text was cut.
    /// Documents are read by the shared extractor: its caps, its cut, and its
    /// own reason on a refusal. The chip only says what the reader reported.
    func testDocumentLoaderReportsCutAndSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let long = dir.appendingPathComponent("Survey export.txt")
        let overCap = ExternalDocumentLoader.maxCharacters + 100
        try String(repeating: "a", count: overCap).write(to: long, atomically: true, encoding: .utf8)
        let cut = try await ExternalDocumentLoader.load(url: long)
        XCTAssertTrue(cut.wasCut, "the shared reader reports the cut")
        XCTAssertEqual(cut.text.count, ExternalDocumentLoader.maxCharacters)
        XCTAssertEqual(cut.kind, .text)
        XCTAssertEqual(cut.byteCount, overCap)
        XCTAssertEqual(cut.ref.wasCut, true)
        XCTAssertEqual(
            ComposerAttachmentDetail.detail(for: cut.ref),
            "\(ComposerAttachmentDetail.byteText(ExternalDocumentLoader.maxCharacters)) · cut"
        )

        let short = dir.appendingPathComponent("notes.md")
        try "Short note".write(to: short, atomically: true, encoding: .utf8)
        let read = try await ExternalDocumentLoader.load(url: short)
        XCTAssertFalse(read.wasCut)

        let big = dir.appendingPathComponent("big.txt")
        try Data(count: ExternalDocumentLoader.maxTextBytes + 1).write(to: big)
        do {
            _ = try await ExternalDocumentLoader.load(url: big)
            XCTFail("a file over the reader's cap is refused, not read")
        } catch {
            XCTAssertEqual(error as? ExternalDocumentLoader.LoadError, .tooLarge)
            XCTAssertEqual((error as? ExternalDocumentLoader.LoadError)?.chipReason, "Too large to attach")
        }
    }

    // MARK: - Fixtures

    private static var stripDocuments: [ComposerDocument] {
        [
            ComposerDocument(name: "Interview notes.md", phase: .reading),
            ComposerDocument(name: "Launch plan.pdf", phase: .ready(attachment(
                name: "Launch plan.pdf", path: "/tmp/Launch plan.pdf",
                kind: .pdf, byteCount: 84_000, pageCount: 12
            ))),
            ComposerDocument(name: "Board pack.pdf", phase: .failed("Too large to attach")),
            ComposerDocument(name: "Survey export.txt", phase: .ready(attachment(
                name: "Survey export.txt", path: "/tmp/Survey export.txt",
                kind: .text, byteCount: 480_000, wasCut: true
            ))),
        ]
    }

    /// A ready attachment carrying the extractor's own record, the way the
    /// loader builds one from a real read.
    private static func attachment(
        name: String,
        path: String,
        kind: ChatAttachmentRef.Kind,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        wasCut: Bool = false,
        limitSummary: String? = nil
    ) -> ExternalDocumentAttachment {
        let isPDF = kind == .pdf
        return ExternalDocumentAttachment(
            name: name,
            text: "Invented.",
            path: path,
            kind: kind,
            byteCount: byteCount,
            pageCount: pageCount,
            wasCut: wasCut,
            document: ExtractedDocument.flat(
                kind: isPDF ? .pdf : .text,
                kindLabel: isPDF ? "PDF" : "Text",
                name: name,
                text: "Invented."
            ),
            limitSummary: limitSummary
        )
    }
}

/// The assist area as the overlay lays it out: a thread above, the composer
/// along the bottom edge, on the opaque `surface` ground. The thread here is
/// a stand-in drawn for the proof (package A owns the real one).
private struct ComposerProofHost: View {
    let seed: ComposerRenderSeed
    var showsThread = true

    var body: some View {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            Group {
                if showsThread {
                    thread
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            AssistantInputView(seed: seed, availableHeight: geometry.size.height)
          }
        }
        .background(House.ColorToken.surface)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            HStack {
                Spacer(minLength: House.Spacing.xxxl)
                Text("What did we decide about the guided tour last time?")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .padding(.horizontal, House.Spacing.sm)
                    .padding(.vertical, House.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                            .fill(House.ColorToken.chipFill)
                    )
            }
            Text("""
            Last week the team kept the guided tour out of the first release. It comes back only \
            if first-screen drop-off passes the agreed threshold. Design has not been told yet.
            """)
            .font(House.TypeToken.body)
            .lineSpacing(HouseChatType.proseLineSpacing)
            .foregroundStyle(House.ColorToken.textPrimary)
            .frame(maxWidth: House.Layout.answerMaxWidth, alignment: .leading)
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.top, House.Spacing.xl)
    }
}
