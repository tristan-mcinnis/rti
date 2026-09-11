import AppKit
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

    // MARK: - Checks

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
    func testDocumentLoaderReportsCutAndSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let long = dir.appendingPathComponent("Survey export.txt")
        try String(repeating: "a", count: ExternalDocumentLoader.maxCharacters + 100).write(to: long, atomically: true, encoding: .utf8)
        let cut = try ExternalDocumentLoader.load(url: long)
        XCTAssertTrue(cut.wasCut)
        XCTAssertEqual(cut.text.count, ExternalDocumentLoader.maxCharacters)
        XCTAssertEqual(cut.kind, .text)
        XCTAssertEqual(cut.byteCount, ExternalDocumentLoader.maxCharacters + 100)
        XCTAssertEqual(cut.ref.wasCut, true)
        XCTAssertEqual(ComposerAttachmentDetail.detail(for: cut.ref), "24 KB · cut")

        let short = dir.appendingPathComponent("notes.md")
        try "Short note".write(to: short, atomically: true, encoding: .utf8)
        XCTAssertFalse(try ExternalDocumentLoader.load(url: short).wasCut)

        let big = dir.appendingPathComponent("big.txt")
        try Data(count: ExternalDocumentLoader.maxBytes + 1).write(to: big)
        XCTAssertThrowsError(try ExternalDocumentLoader.load(url: big)) { error in
            XCTAssertEqual(error as? ExternalDocumentLoader.LoadError, .tooLarge)
            XCTAssertEqual((error as? ExternalDocumentLoader.LoadError)?.chipReason, "Over 512 KB; not read")
        }
    }

    // MARK: - Fixtures

    private static var stripDocuments: [ComposerDocument] {
        [
            ComposerDocument(name: "Interview notes.md", phase: .reading),
            ComposerDocument(name: "Launch plan.pdf", phase: .ready(ExternalDocumentAttachment(
                name: "Launch plan.pdf", text: "Invented.", path: "/tmp/Launch plan.pdf",
                kind: .pdf, byteCount: 84_000, pageCount: 12
            ))),
            ComposerDocument(name: "Board pack.pdf", phase: .failed("Over 512 KB; not read")),
            ComposerDocument(name: "Survey export.txt", phase: .ready(ExternalDocumentAttachment(
                name: "Survey export.txt", text: "Invented.", path: "/tmp/Survey export.txt",
                kind: .text, byteCount: 480_000, wasCut: true
            ))),
        ]
    }
}

/// The assist area as the overlay lays it out: a thread above, the composer
/// along the bottom edge, on the opaque `surface` ground. The thread here is
/// a stand-in drawn for the proof (package A owns the real one).
private struct ComposerProofHost: View {
    let seed: ComposerRenderSeed
    var showsThread = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsThread {
                    thread
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            AssistantInputView(seed: seed)
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
