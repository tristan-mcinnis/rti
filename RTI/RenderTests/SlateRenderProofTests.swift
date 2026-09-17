import AppKit
import RTICore
import SwiftUI
import XCTest

/// Offscreen render proof for the Slate redesign.
///
/// Rendering, the output folder (`/tmp/rti-render-proof/`), and the fixture
/// vault come from the shared harness (`RenderProofHarness`,
/// `RenderProofTestCase`); sample content from `RenderFixtures`. The PNGs
/// are compared by eye against the Claude Design mockups (`rti.dc.html`,
/// direction 1b "Slate").
///
/// These tests assert only that a non-blank bitmap of the expected size came
/// out; the design comparison is the human (or agent) reading the PNGs.
final class SlateRenderProofTests: RenderProofTestCase {
    // MARK: - Screens

    func testOverlayAssistTab() throws {
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        SessionCoordinator.shared.seedForRenderProof(
            entries: [], interim: nil, phase: .recording, startedAt: Date().addingTimeInterval(-761)
        )
        try renderBothAppearances(
            name: "overlay-assist",
            size: CGSize(width: 700, height: 440),
            view: OverlayPanelView(modes: ModeStore.inMemory())
        )
    }

    func testOverlayTranscriptTab() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns,
            interim: "Sure, I'll write it up after this and tag the design channel so…",
            phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        try renderBothAppearances(
            name: "overlay-transcript",
            size: CGSize(width: 700, height: 440),
            view: OverlayPanelView(modes: ModeStore.inMemory())
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
            entries: RenderFixtures.speakerTurns,
            interim: nil,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-211)
        )
        try renderBothAppearances(
            name: "overlay-minimum-width",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440),
            view: OverlayPanelView(modes: ModeStore.inMemory())
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
            entries: RenderFixtures.speakerTurns,
            interim: nil,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-211)
        )
        try renderBothAppearances(
            name: "overlay-transcript-minimum-width",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 440),
            view: OverlayPanelView(modes: ModeStore.inMemory())
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
            view: SettingsView(onClose: {}, initialSection: .general, modeStore: ModeStore.inMemory())
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
        CommandRegistry.shared.replaceAll(RenderFixtures.commands)
        try renderBothAppearances(
            name: "command-palette",
            size: CGSize(width: 620, height: 420),
            view: CommandPaletteView(query: .constant(""), onRun: { _ in })
                .frame(width: 620, height: 420)
        )
    }
}
