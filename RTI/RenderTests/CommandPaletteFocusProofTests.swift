import AppKit
import RTICore
import SwiftUI
import XCTest
import HouseDesign

/// The `⌘K` palette must own the keys from the moment it is up: typing goes
/// into its search field, and the composer must not pull them back.
///
/// The regression (2026-09-14): `⌘K` drew the palette, but the window's
/// own "became key" notification (posted one runloop turn after `⌘K`, and
/// again 50 ms after `show()`) asked the composer for the keys. That focus
/// request landed *after* the palette claimed focus, so the composer kept
/// first responder: typing landed in the draft, the palette's query stayed
/// on its placeholder, and `↑↓` did nothing.
///
/// This is the strongest seam a host-less bundle can reach: the live
/// `AssistantInputView` hosted in a real, key panel. The panel is
/// non-activating and held far off screen (`OffscreenPanel`), so it never
/// appears and never takes focus from another app.
@MainActor
final class CommandPaletteFocusProofTests: XCTestCase {
    private var window: OffscreenPanel!

    override func setUp() async throws {
        try await super.setUp()
        try RenderProofHarness.prepare()
        OverlayInputState.shared.mode = .chat
        window = makeWindow()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        assertNoOnscreenWindow("after the panel is closed")
        window = nil
        OverlayInputState.shared.mode = .chat
        try await super.tearDown()
    }

    /// `⌘K` opens the palette and it keeps the keys, even when the overlay's
    /// become-key notification arrives right after.
    func test_paletteKeepsTheKeysWhenTheOverlayBecomesKeyJustAfterItOpens() throws {
        let composer = try mountComposer()

        try key("k", keyCode: 40, modifiers: .command)
        settle()
        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "⌘K must move the keys to the palette, was \(String(describing: window.firstResponder))"
        )

        // The window's key notification arrives now, as it does in the app.
        NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        settle()

        XCTAssertFalse(
            window.firstResponder === composer,
            "the composer must not take the keys back from the palette"
        )
        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "first responder must stay the palette's search field, was \(String(describing: window.firstResponder))"
        )

        try type("who")
        XCTAssertEqual(composer.string, "", "nothing may land in the composer draft")
        XCTAssertEqual(
            (window.firstResponder as? NSTextView)?.string, "who",
            "typing must fill the palette's search field"
        )
    }

    /// Down Arrow then Return runs the second row. The palette is mounted on
    /// its own with three injected, harmless commands and a query that matches
    /// only them, so no registry row can take the selection and no command
    /// touches the app.
    func test_downArrowThenReturnRunsTheSecondRow() throws {
        let probe = PaletteProbe()
        let host = NSHostingView(rootView: PaletteTestHost(probe: probe))
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        settle()
        assertNoOnscreenWindow("while the palette is live")

        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "the palette claims the keys after it appears, was \(String(describing: window.firstResponder))"
        )

        try type("zzz")
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "zzz", "typing must reach the palette's query")

        // ↓ then ↩, through the window, exactly as a user presses them.
        try specialKey(0xF701, keyCode: 125)
        try key("\r", keyCode: 36, modifiers: [])

        XCTAssertEqual(probe.ran, ["test.harmless.two"], "↓ then ↩ must run the second row")

        // ⌘K and Esc must still close while the field editor holds the keys.
        // A command chord is a key equivalent: AppKit routes it through the
        // window's key-equivalent path, not through `sendEvent` into the
        // field editor, so the test enters there.
        let handled = try keyEquivalent("k", keyCode: 40, modifiers: .command)
        XCTAssertTrue(handled, "⌘K must be handled as a key equivalent")
        XCTAssertEqual(probe.closeCount, 1, "⌘K must close the palette")
        try specialKey(0x1B, keyCode: 53)
        XCTAssertEqual(probe.closeCount, 2, "Escape must close the palette")
    }

    func testLongChooserBuildsOnlyViewportRowsAndScrollsToLastResult() throws {
        let audit = RenderedRows()
        let host = NSHostingView(rootView: ChooserWindowProof(rows: audit))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 190)
        window.contentView?.addSubview(host)
        settle()
        XCTAssertTrue(audit.seen.contains(0))
        XCTAssertLessThan(audit.seen.count, 30, "opening a five-row viewport must not construct the full result set")
        audit.selected = 149
        settle()
        XCTAssertTrue(audit.seen.contains(149), "a selection beyond the visible page must scroll into view")
    }

    @Observable @MainActor
    final class RenderedRows {
        var selected = 0
        @ObservationIgnored var seen: Set<Int> = []
    }

    private struct ChooserWindowProof: View {
        let rows: RenderedRows

        var body: some View {
            ChooserList(items: Array(0 ..< 150), selectedIndex: rows.selected, maxRows: 5) { _, number in
                row(number)
            }
        }

        private func row(_ number: Int) -> some View {
            rows.seen.insert(number)
            return Text("Action \(number)").frame(height: House.Control.row)
        }
    }

    /// Opt in explicitly. The session and all source turns are invented. Keep
    /// this hostless so repeated routes never register system shortcuts.
    func testLongWorkspaceMemoryAndInteractions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RTI_LONG_WORKSPACE"] == "1")
        let session = SessionCoordinator.shared
        let llm = LLMController.shared
        llm.callTypeStore.active = .research
        let model = WorkspaceModel()
        let workspace = NSHostingView(rootView: WorkspaceView(model: model, callTypes: llm.callTypeStore))
        window.setContentSize(WorkspaceLayout.standardSize)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        workspace.frame = try XCTUnwrap(window.contentView).bounds
        window.contentView?.addSubview(workspace)
        defer { workspace.removeFromSuperview() }

        let registry = CommandBuilder.buildCommands(windows: .shared, session: session, llm: llm, callTypes: llm.callTypeStore)
        CommandRegistry.shared.replaceAll(registry)
        let roots = try XCTUnwrap(ChatThreadStore.applicationRoots())
        XCTAssertTrue(roots.threads.path.hasPrefix(try XCTUnwrap(FixtureVault.root).path + "/"))
        let store = try ChatThreadStore(roots: roots)
        for index in 0 ..< 24 {
            let chat = try await store.thread(id: "stress-\(index)", title: "Sample \(index)", surface: .rtiCopilot,
                                               session: nil, appVersion: "test")
            _ = try await store.appendTurn(to: chat, turn: .init(text: "Invented saved question \(index)."))
        }
        try await Task.sleep(for: .milliseconds(200))
        let initial = try recordMemory("initial", cycle: 0)
        var resetMemory: [Double] = []

        for cycle in 1 ... 3 {
            let start = Date(timeIntervalSinceNow: -92 * 60)
            session.beginTranscriptReplayForProof(startedAt: start)
            llm.seedForRenderProof(entries: (0 ..< 24).map { index in
                ChatEntry(role: index.isMultiple(of: 2) ? "user" : "assistant",
                          text: "Invented live message \(index).", action: nil, contextUsed: true, screenContextUsed: false)
            })
            showTab("transcript")
            // Every simulated minute delivers 20 final provider batches. The
            // real 120 ms publisher updates the visible reader between minutes.
            for minute in 0 ... 92 {
                for index in 0 ..< 20 {
                    let ordinal = minute * 20 + index
                    let ms = ordinal * 3_000
                    let local = ordinal.isMultiple(of: 3)
                    let word = SonioxWord(text: local ? "Describe sample \(ordinal)." : "我选择样例\(ordinal)。",
                        startMs: ms, endMs: ms + 800, speaker: local ? 0 : 2, confidence: 0.99, isFinal: true,
                        translationStatus: "original", language: local ? "en" : "zh", sourceLanguage: nil)
                    session.receiveTranscriptWordsForProof([word], channel: local ? "mic" : "system")
                }
                try await Task.sleep(for: .milliseconds(125))
            }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(session.liveEntries.count, 1860)
            seedCodebook(from: session.liveEntries, cycle: cycle)
            _ = try recordMemory("recorded", cycle: cycle)

            for _ in 0 ..< 4 {
                showTab("transcript")
                try await Task.sleep(for: .milliseconds(80))
                workspace.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(readerScrollView(workspace))
                let range = max(0, try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height)
                for fraction in [0.75, 0.33, 1.0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    workspace.layoutSubtreeIfNeeded()
                }
                if OverlayTab(rawValue: "codebook") != nil {
                    showTab("codebook")
                    try await Task.sleep(for: .milliseconds(80))
                }
                model.select(.chats)
                try await Task.sleep(for: .milliseconds(80))
                model.select(.sessions)
                try await Task.sleep(for: .milliseconds(80))
                model.select(.live)
                showTab("assist")
                try await Task.sleep(for: .milliseconds(100))
                let composer = try XCTUnwrap(composerTextView())
                XCTAssertTrue(window.makeFirstResponder(composer))
                try window.sendEvent(keyEvent("k", keyCode: 40, modifiers: .command))
                try await Task.sleep(for: .milliseconds(100))
                let field = try XCTUnwrap(chooserField(workspace))
                window.makeFirstResponder(field)
                for (letter, code) in [("s", UInt16(1)), ("e", 14), ("t", 17)] {
                    try window.sendEvent(keyEvent(letter, keyCode: code, modifiers: []))
                    workspace.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(field.stringValue, "set")
                XCTAssertTrue(try window.performKeyEquivalent(with: keyEvent("k", keyCode: 40, modifiers: .command)))
                try await Task.sleep(for: .milliseconds(80))
            }
            _ = try recordMemory("interacted", cycle: cycle)
            session.endTranscriptReplayForProof()
            ResearchCodebookController.shared.seedForRenderProof(ResearchCodebook())
            llm.seedForRenderProof(entries: [])
            model.select(.live)
            showTab("assist")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(session.liveEntries.isEmpty)
            resetMemory.append(try recordMemory("reset", cycle: cycle))
        }
        // Allocators/frameworks may keep their first allocation. Compare
        // equivalent warm resets, and catch re-retaining a large session.
        XCTAssertLessThan(resetMemory[2] - resetMemory[0], 64,
                          "footprint grew more than 64 MiB across equivalent warm resets; initial \(initial)")
        assertNoOnscreenWindow("after endurance replay")
    }

    private func seedCodebook(from source: [LiveEntry], cycle: Int) {
        var book = ResearchCodebook()
        for n in 0 ..< 16 { book.seed("Fixture concept \(n)") }
        let evidence = (0 ..< 96).map { n in
            let entry = source[n * 10 + 1]
            return ResearchQuote(sessionID: "scope-\(cycle)", turnID: entry.id.uuidString, group: "G\(cycle)",
                                 offsetMs: entry.startMs, original: entry.text,
                                 speaker: .init(rawSpeaker: entry.speakerId, label: "Them", leg: "Them",
                                                confidence: "legOnly", seat: nil, segment: nil, moderator: false),
                                 revealRecorded: false)
        }
        let items = evidence.enumerated().map { n, quote in
            ResearchProposal.Item(name: "Fixture concept \(n % 16)", aliases: [], type: .concept,
                                  turnID: quote.turnID, point: "Sample \(n)", valence: .neutral)
        }
        book.apply(ResearchProposal(entries: items, names: nil), sources: evidence)
        ResearchCodebookController.shared.seedForRenderProof(book)
        XCTAssertEqual(book.cards.count, 16)
        XCTAssertEqual(book.cards.flatMap(\.entries).count, 96)
    }

    private func showTab(_ id: String) {
        NotificationCenter.default.post(name: .rtiSelectTab, object: id)
    }

    private func chooserField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Search actions" { return field }
        return view.subviews.lazy.compactMap(chooserField).first
    }

    private func readerScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > 1_000 { return scroll }
        return view.subviews.lazy.compactMap(readerScrollView).first
    }

    private func recordMemory(_ label: String, cycle: Int) throws -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) { pointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), pointer, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        let mib = 1024.0 * 1024
        let resident = Double(info.resident_size) / mib
        let footprint = Double(info.phys_footprint) / mib
        print(String(format: "RTI_WORKSPACE_MEMORY %d,%@,%.2f,%.2f", cycle, label, resident, footprint))
        return footprint
    }

    // MARK: - Helpers

    func test_shiftCommandAOpensAttachAndKeepsTheDraft() throws {
        let composer = try mountComposer()
        try type("Synthetic draft")
        let original = composer.string
        XCTAssertTrue(try keyEquivalent("a", keyCode: 0, modifiers: [.command, .shift]))
        settle()
        XCTAssertEqual(composer.string, original)
        // Escape closes Add Context; it must not clear the text behind it.
        try specialKey(0x1B, keyCode: 53)
        XCTAssertEqual(composer.string, original)
    }

    /// The same proof for the key Quick Launch binds: ⇧⌘S. The composer's
    /// field editor must take it as a key equivalent, not hand it on.
    func test_shiftCommandSOpensAttachAndKeepsTheDraft() throws {
        let composer = try mountComposer()
        try type("Synthetic draft")
        let original = composer.string
        XCTAssertTrue(try keyEquivalent("s", keyCode: 1, modifiers: [.command, .shift]))
        settle()
        XCTAssertEqual(composer.string, original)
        try specialKey(0x1B, keyCode: 53)
        XCTAssertEqual(composer.string, original)
    }

    /// Hosts the live composer and leaves it holding the keys, as the overlay
    /// leaves it.
    private func mountComposer() throws -> NSTextView {
        let host = NSHostingView(rootView: AssistantInputView(seed: ComposerRenderSeed()))
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        settle()
        assertNoOnscreenWindow("while the composer is live")

        let composer = try XCTUnwrap(composerTextView(), "the composer field is mounted")
        window.makeFirstResponder(composer)
        XCTAssertTrue(window.firstResponder === composer, "the composer starts with the keys")
        return composer
    }

    /// A far-off-screen, non-activating panel. It is never ordered front, so
    /// it is never drawn and never takes focus from another app; AppKit still
    /// gives its views a window, which is all the field focus needs.
    private func makeWindow() -> OffscreenPanel {
        let panel = OffscreenPanel(
            contentRect: NSRect(x: -20000, y: -20000, width: 620, height: 460),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        // The panel's initializer puts a new window on a visible screen; the
        // override above only takes effect from here on.
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        return panel
    }

    /// No window of this process is on a screen. On-screen-only CG window
    /// info is keyed by owner pid and needs no screen-recording grant.
    private func assertNoOnscreenWindow(_ context: String) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let ours = onScreen.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
        }
        XCTAssertTrue(ours.isEmpty, "\(context): a test window reached the screen: \(ours)")
        if let window {
            XCTAssertFalse(
                NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                "\(context): the test panel sits on a screen"
            )
        }
    }

    /// An `NSPanel` whose frame is never constrained onto a screen. AppKit
    /// moves a fully offscreen window into view when one is ordered front
    /// (its default `constrainFrameRect`), which is how an earlier version of
    /// this test put a real panel on screen at 10:34.
    private final class OffscreenPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// A SwiftUI `TextField`'s first responder is the window's field editor,
    /// whose delegate is its `NSTextField`; the composer's own text view has
    /// no such delegate.
    private func isPaletteSearchField(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextView)?.delegate is NSTextField
    }

    private func composerTextView() -> NSTextView? {
        guard let root = window.contentView else { return nil }
        return collectTextViews(in: root).first { !$0.isFieldEditor }
    }

    private func collectTextViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let textView = view as? NSTextView {
            found.append(textView)
        }
        for subview in view.subviews {
            found.append(contentsOf: collectTextViews(in: subview))
        }
        return found
    }

    private func settle() {
        for _ in 0 ..< 6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private func type(_ text: String) throws {
        for character in text {
            try key(String(character), keyCode: 0, modifiers: [])
        }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        try send(characters, keyCode: keyCode, modifiers: modifiers)
    }

    /// A key that has no text, like Down Arrow, sent with its function-key
    /// character so AppKit and SwiftUI read it as that key.
    private func specialKey(_ scalar: UInt32, keyCode: UInt16) throws {
        let characters = String(Character(UnicodeScalar(scalar)!))
        try send(characters, keyCode: keyCode, modifiers: [])
    }

    private func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        try window.sendEvent(keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        settle()
    }

    /// A command chord, entered the way `NSApplication` enters it: the key
    /// window's key-equivalent path, which reaches the palette's field.
    private func keyEquivalent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> Bool {
        let handled = try window.performKeyEquivalent(with: keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        settle()
        return handled
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// Holds the palette's query binding for a test that mounts it directly.
    @MainActor
    private final class PaletteProbe {
        var ran: [String] = []
        var closeCount = 0
    }

    /// Mounts `CommandPaletteView` the way the composer does, on a real
    /// `@State` query (a plain object would not drive `.onChange`), over three
    /// harmless injected commands and nothing the registry can match.
    private struct PaletteTestHost: View {
        let probe: PaletteProbe

        var body: some View {
            CommandPaletteView(
                onRun: { probe.ran.append($0.id) },
                onClose: { probe.closeCount += 1 },
                leadingCommands: [
                    RTICommand(id: "test.harmless.one", title: "Zzz one", keywords: ["zzz"], perform: {}),
                    RTICommand(id: "test.harmless.two", title: "Zzz two", keywords: ["zzz"], perform: {}),
                    RTICommand(id: "test.harmless.three", title: "Zzz three", keywords: ["zzz"], perform: {}),
                ]
            )
            .background(House.ColorToken.surface)
        }
    }
}
