import AppKit
import RTICore
import SwiftUI
import XCTest

/// Offscreen render proof for the Slate redesign.
///
/// Every screen is hosted in an NSHostingView inside an OFFSCREEN window
/// (never ordered front, never activated) and captured with
/// `cacheDisplay(in:to:)` in both `.darkAqua` and `.aqua`. The PNGs land in
/// `/tmp/rti-render-proof/` and are compared by eye against the Claude Design
/// mockups (`rti.dc.html`, direction 1b "Slate").
///
/// These tests assert only that a non-blank bitmap of the expected size came
/// out; the design comparison is the human (or agent) reading the PNGs.
@MainActor
final class SlateRenderProofTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/rti-render-proof", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        SlateRenderMode.flattenGlass = true
        try? FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Screens

    func testOverlayAssistTab() throws {
        LLMController.shared.seedForRenderProof(entries: Fixtures.assistTurns)
        SessionCoordinator.shared.seedForRenderProof(
            entries: [], interim: nil, phase: .recording, startedAt: Date().addingTimeInterval(-761)
        )
        try renderBothAppearances(
            name: "overlay-assist",
            size: CGSize(width: 700, height: 440),
            view: OverlayPanelView()
        )
    }

    func testOverlayTranscriptTab() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: Fixtures.speakerTurns,
            interim: "Sure, I'll write it up after this and tag the design channel so…",
            phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        try renderBothAppearances(
            name: "overlay-transcript",
            size: CGSize(width: 700, height: 440),
            view: OverlayPanelView()
                .onAppear { NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue) }
        )
    }

    func testOverlayMinimumWidth() throws {
        let originalPrimaryActionID = LLMController.shared.primaryActionID
        defer {
            LLMController.shared.primaryActionID = originalPrimaryActionID
            SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        }
        LLMController.shared.primaryActionID = "recap"
        SessionCoordinator.shared.seedForRenderProof(
            entries: Fixtures.speakerTurns,
            interim: nil,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-211)
        )
        try renderBothAppearances(
            name: "overlay-minimum-width",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440),
            view: OverlayPanelView()
        )
        XCTAssertEqual(OverlayAppearanceDefaults.widthRange.lowerBound, 600)
    }

    func testOverlayTranscriptAtMinimumWidth() throws {
        defer {
            SpeakerNameStore.shared.reset()
            SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        }
        SpeakerNameStore.shared.rename("them_1", to: "A deliberately long participant name")
        SessionCoordinator.shared.seedForRenderProof(
            entries: Fixtures.speakerTurns,
            interim: nil,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-211)
        )
        try renderBothAppearances(
            name: "overlay-transcript-minimum-width",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440),
            view: OverlayPanelView()
                .onAppear { NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue) }
        )
    }

    func testIdleNoteAppendsToMeetingPrepNote() {
        let store = MeetingContextStore.shared
        store.resetAfterSession()
        store.note = "Existing context"

        XCTAssertTrue(store.appendPrepNote("  Ask about pricing  "))
        XCTAssertEqual(store.note, "Existing context\nAsk about pricing")
        XCTAssertEqual(
            store.summaryContext,
            "User prep note for this meeting:\nExisting context\nAsk about pricing"
        )

        store.resetAfterSession()
    }

    func testSettingsGeneral() throws {
        try renderBothAppearances(
            name: "settings-general",
            size: CGSize(width: 860, height: 560),
            view: SettingsView(onClose: {}, initialSection: .general)
        )
    }

    func testSessionsBrowser() throws {
        try renderBothAppearances(
            name: "sessions-browser",
            size: CGSize(width: 980, height: 620),
            view: SessionsBrowserView()
        )
    }

    func testOnboarding() throws {
        try renderBothAppearances(
            name: "onboarding",
            size: CGSize(width: 520, height: 640),
            view: OnboardingView(onDone: {})
        )
    }

    func testCommandPalette() throws {
        CommandRegistry.shared.replaceAll(Fixtures.commands)
        try renderBothAppearances(
            name: "command-palette",
            size: CGSize(width: 620, height: 420),
            view: CommandPaletteView(query: .constant(""), onRun: { _ in })
                .frame(width: 620, height: 420)
        )
    }

    // MARK: - Harness

    private func renderBothAppearances(name: String, size: CGSize, view: some View) throws {
        for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let url = Self.outputDirectory.appendingPathComponent("\(name)-\(suffix).png")
            let png = try render(view, size: size, appearance: appearanceName)
            try png.write(to: url)
            XCTAssertGreaterThan(png.count, 2_000, "\(url.lastPathComponent) looks blank")
        }
    }

    /// Lay the view out in a window-less NSHostingView and capture it.
    ///
    /// No NSWindow is created and no NSApplication is started, so nothing can
    /// reach the screen: the bitmap is drawn straight out of the view tree.
    /// The appearance is forced two ways at once — the view's `appearance`
    /// (which is what House's dynamic NSColors resolve against) and the app's
    /// own theme setting (which drives `.preferredColorScheme`).
    private func render(_ view: some View, size: CGSize, appearance name: NSAppearance.Name) throws -> Data {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        UserDefaults.standard.set(
            name == .darkAqua ? RTIAppearanceMode.dark.rawValue : RTIAppearanceMode.light.rawValue,
            forKey: OverlayAppearanceDefaults.appearanceModeKey
        )

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Two runloop turns: one for SwiftUI's first layout, one for state that
        // lands in .onAppear (tab selection, list loads).
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
        }

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return try XCTUnwrap(data)
    }
}

// MARK: - Fixtures

/// The same sample content the Claude Design mockup uses, so the PNGs can be
/// diffed against the tiles side by side.
@MainActor
private enum Fixtures {
    static var assistTurns: [ChatEntry] { [
        ChatEntry(role: "user", text: "Assist", action: "Assist", contextUsed: true, screenContextUsed: false),
        ChatEntry(
            role: "assistant",
            text: """
            They've just agreed to drop the guided tour and measure first-screen drop-off instead. \
            Speaker 2 is taking the decision note; design hasn't been told yet.

            Worth raising now: who defines the drop-off threshold that would bring the tour back, \
            and by when. That decides whether "point-one" is a real commitment.
            """,
            action: nil,
            contextUsed: false,
            screenContextUsed: false
        ),
    ] }

    static var speakerTurns: [LiveEntry] { [
        entry("them_1", "So the main thing we need to lock this week is the onboarding scope. If we keep the guided tour, the launch slips by a sprint.", 723_000),
        entry("them_2", "I'd rather ship without the tour and measure drop-off on the first screen. We can add it back in point-one if the numbers say so.", 741_000),
        entry("them_1", "Fine by me. Can you own the decision note so design isn't surprised on Thursday?", 758_000),
    ] }

    /// A slice of the real registry shape: title plus the shortcut hint the
    /// palette draws as key caps.
    static var commands: [RTICommand] { [
        RTICommand(id: "session.start", title: "Start Recording", subtitle: "⌘⇧R", perform: {}),
        RTICommand(id: "session.pause", title: "Pause Recording", subtitle: "⌘⇧P", perform: {}),
        RTICommand(id: "overlay.toggle", title: "Toggle Overlay", subtitle: "⌘\\", perform: {}),
        RTICommand(id: "action.assist", title: "Assist", subtitle: "⌘⏎", perform: {}),
        RTICommand(id: "note.quick", title: "Quick Note", subtitle: "⌘⌥N", perform: {}),
        RTICommand(id: "view.sessions", title: "Open Sessions", subtitle: nil, perform: {}),
        RTICommand(id: "settings.open", title: "Settings…", subtitle: "⌘,", perform: {}),
    ] }

    private static func entry(_ speaker: String, _ text: String, _ startMs: Int) -> LiveEntry {
        LiveEntry(
            speakerId: speaker,
            text: text,
            startMs: startMs,
            confidence: 0.95,
            translationStatus: "none",
            language: "en",
            sourceLanguage: nil
        )
    }
}
