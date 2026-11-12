import AppKit
import RTICore
import SwiftUI
import XCTest
import HouseDesign

/// Package C proofs: the overlay shell. The header in every session phase,
/// the tabs row, the tab strips and empty hints, the Prepare tab, the
/// header's in-window chooser, and Keep on Top, at the standard 700 and the
/// minimum 600 widths. PNG prefix `shell-`.
///
/// Content comes from `RenderFixtures` and the fixture vault; the Prepare
/// tab's calendar read is off, so no proof reads a real meeting.
final class OverlayShellRenderProofTests: RenderProofTestCase {
    private static let standardWidth = OverlayAppearanceDefaults.defaultWidth
    private static let minimumWidth = OverlayAppearanceDefaults.widthRange.lowerBound

    private var savedDefaults: [String: Any?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
        for key in [NotesSettings.enabledKey, AutoAssistSettings.enabledKey] {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() async throws {
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        OverlayShellModel.shared.chooser = nil
        OverlayWindowChrome.shared.isKeptOnTop = false
        MeetingContextStore.shared.resetAfterSession()
        LLMController.shared.seedForRenderProof(entries: [])
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    // MARK: - Header, every phase

    func testHeaderStates() throws {
        seedRecording()
        try renderBothAppearances(
            name: "shell-header-states",
            size: CGSize(width: Self.standardWidth, height: HeaderStatesSheet.height),
            view: HeaderStatesSheet()
        )
    }

    func testHeaderStatesAtMinimumWidth() throws {
        seedRecording()
        try renderBothAppearances(
            name: "shell-header-states-minimum-width",
            size: CGSize(width: Self.minimumWidth, height: HeaderStatesSheet.height),
            view: HeaderStatesSheet()
        )
    }

    /// A calendar event names the meeting, so before the recording the
    /// project chip carries the project's name too; while capture runs (and
    /// at 600) it is the glyph alone.
    func testHeaderWithCalendarTitleAndProject() throws {
        seedRecording()
        pickProjectAndEvent()
        for (suffix, width) in [("", Self.standardWidth), ("-minimum-width", Self.minimumWidth)] {
            try renderBothAppearances(
                name: "shell-header-calendar\(suffix)",
                size: CGSize(width: width, height: 2 * (House.Control.composer + House.hairline)),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: OverlayShellStatus(phase: .idle), callTypes: .inMemory())
                    HouseDivider()
                    OverlayShellHeader(status: OverlayShellStatus(phase: .recording), callTypes: .inMemory())
                    HouseDivider()
                }
                .background(House.ColorToken.surface)
            )
        }
    }

    // MARK: - Whole overlay

    func testAssistWhileRecording() throws {
        seedRecording()
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        try renderPanel("shell-assist-recording", widths: [Self.standardWidth, Self.minimumWidth])
    }

    func testIdleWithProject() throws {
        pickProject()
        try renderPanel("shell-idle-project", widths: [Self.standardWidth])
    }

    func testSessionSaved() throws {
        SessionCoordinator.shared.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .done, startedAt: nil)
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        try renderPanel(
            "shell-session-saved",
            widths: [Self.standardWidth, Self.minimumWidth],
            status: OverlayShellStatus(phase: .done, processingStatus: "Session saved")
        )
    }

    /// Every tab that can show without a guide: Notes on, and Auto on (no tab
    /// of its own; at these widths its rail folds into the one-line strip).
    func testTabsRowWithEveryTab() throws {
        enableEveryTab()
        seedRecording()
        try renderPanel("shell-tabs-all", widths: [Self.standardWidth, Self.minimumWidth], tab: .transcript)
    }

    func testTranscriptTab() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns,
            interim: "Sure, I'll write it up after this and tag the design channel so…",
            phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        try renderPanel("shell-transcript", widths: [Self.standardWidth, Self.minimumWidth], tab: .transcript)
    }

    /// Auto is on by default on a client call, so the rail sits beside the
    /// transcript. At the breakpoint, the tightest width that keeps the rail
    /// rather than the strip, the transcript's Translate and copy controls
    /// must still fit beside it (the breakpoint is about 750 pt, so this is
    /// tighter than any wider window). PNG `shell-transcript-rail-<width>`.
    func testTranscriptBesideTheRailAtTheBreakpoint() throws {
        UserDefaults.standard.removeObject(forKey: AutoAssistSettings.enabledKey)
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns,
            interim: "Sure, I'll write it up after this and tag the design channel so…",
            phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        let width = Double(LiveRailLayout.stripBelow)
        XCTAssertEqual(LiveRailLayout.mode(width: width, applies: true), .rail)
        XCTAssertGreaterThan(width, Self.standardWidth, "the standard width shows the strip, so this proof covers the rail")
        try renderPanel("shell-transcript-rail-\(Int(width))", widths: [width], tab: .transcript)
    }

    func testTranscriptEmpty() throws {
        try renderPanel("shell-transcript-empty", widths: [Self.standardWidth], tab: .transcript)
    }

    /// Auto has no tab (its cards sit in the rail beside the transcript), so
    /// the empty proof covers Notes alone.
    func testEmptyNotesTab() throws {
        enableEveryTab()
        seedRecording(entries: [])
        try renderPanel("shell-notes-empty", widths: [Self.standardWidth, Self.minimumWidth], tab: .notes)
    }

    func testPrepareTab() throws {
        enableEveryTab()
        try renderPanel(
            "shell-prepare",
            widths: [Self.standardWidth, Self.minimumWidth],
            height: OverlayAppearanceDefaults.heightRange.upperBound,
            tab: .setup
        )
    }

    // MARK: - Header layers

    func testModelChooser() throws {
        seedRecording()
        OverlayShellModel.shared.chooser = .model
        try renderPanel("shell-chooser-model", widths: [Self.standardWidth])
    }

    func testCallTypeChooser() throws {
        seedRecording()
        OverlayShellModel.shared.chooser = .callType
        try renderPanel("shell-chooser-call-type", widths: [Self.minimumWidth])
    }

    func testKeptOnTop() throws {
        seedRecording()
        OverlayWindowChrome.shared.isKeptOnTop = true
        try renderPanel("shell-kept-on-top", widths: [Self.standardWidth])
    }

    // MARK: - Seams

    /// The ⌘1…⌘7 order in RTICore is the tab order the overlay draws, plus
    /// the kept ⌘3 slot of the deleted Auto tab, which opens Transcript.
    func testTabShortcutsMatchTheTabs() {
        XCTAssertEqual(OverlayTab.allCases.map(\.rawValue), OverlayTabShortcut.order.filter { $0 != OverlayTabShortcut.liveHelpSlot })
        XCTAssertEqual(OverlayTabShortcut.order.firstIndex(of: OverlayTabShortcut.liveHelpSlot), 2)
        XCTAssertEqual(OverlayTab.setup.shortcutLabel, "⌘1")
        XCTAssertEqual(OverlayTab.transcript.shortcutLabel, "⌘4")
        XCTAssertEqual(OverlayTab.notes.shortcutLabel, "⌘5")
    }

    /// Each session phase maps to the header's phase of the same name.
    func testPhaseMapping() {
        let phases: [SessionCoordinator.Phase] = [.idle, .recording, .paused, .finishing, .upgrading, .done]
        XCTAssertEqual(phases.map(\.livePhase.rawValue), ["idle", "recording", "paused", "finishing", "upgrading", "done"])
    }

    /// `esc` never hides the overlay: with nothing open it does nothing, and
    /// the header chooser is the first layer it closes.
    func testEscapeClosesTheHeaderChooserFirst() {
        let router = OverlayEscapeRouter.shared
        OverlayShellModel.shared.registerEscape()
        OverlayShellModel.shared.chooser = nil
        XCTAssertEqual(router.handleEscape(), .nothing)

        OverlayShellModel.shared.chooser = .model
        XCTAssertEqual(router.handleEscape(), .closeLayer)
        XCTAssertNil(OverlayShellModel.shared.chooser)
    }

    /// No key window means no RTI window is key, for the menu bar's
    /// validation. (Identifiers are pinned in `MenuValidationTests`; a proof
    /// never creates a window.)
    func testNoKeyWindowIsNone() {
        XCTAssertEqual(RTIKeyWindowTracker.kind(of: nil), .none)
    }

    // MARK: - Helpers

    private func seedRecording(entries: [LiveEntry] = RenderFixtures.speakerTurns) {
        SessionCoordinator.shared.seedForRenderProof(
            entries: entries,
            interim: nil,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
    }

    private func enableEveryTab() {
        for key in [NotesSettings.enabledKey, AutoAssistSettings.enabledKey] {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private func pickProject() {
        let store = MeetingContextStore.shared
        let item = VaultItem(
            id: "projects/northwind",
            name: "Northwind app",
            url: URL(fileURLWithPath: "/tmp/northwind"),
            isProject: true
        )
        store.workstreamItem = item
        store.workstreamName = item.name
    }

    private func pickProjectAndEvent() {
        pickProject()
        MeetingContextStore.shared.selectCalendarMeeting(CalendarMeeting(
            id: "fixture-event",
            title: "Onboarding scope review",
            startDate: Date().addingTimeInterval(-761),
            endDate: Date().addingTimeInterval(1_800)
        ))
    }

    private func renderPanel(
        _ name: String,
        widths: [Double],
        height: Double = OverlayAppearanceDefaults.defaultHeight,
        tab: OverlayTab? = nil,
        status: OverlayShellStatus? = nil
    ) throws {
        for width in widths {
            let suffix = width == Self.minimumWidth ? "-minimum-width" : ""
            try renderBothAppearances(
                name: "\(name)\(suffix)",
                size: CGSize(width: width, height: height),
                view: OverlayPanelView(statusOverride: status, callTypes: CallTypeStore.inMemory())
                    .onAppear {
                        if let tab {
                            NotificationCenter.default.post(name: .rtiSelectTab, object: tab.rawValue)
                        }
                    }
            )
        }
    }
}

// MARK: - The header sheet

/// The header in each phase, one under another, so one PNG compares them.
/// The hairlines between rows are proof-only.
private struct HeaderStatesSheet: View {
    static let states: [OverlayShellStatus] = [
        OverlayShellStatus(phase: .idle),
        OverlayShellStatus(phase: .recording),
        OverlayShellStatus(phase: .paused),
        OverlayShellStatus(phase: .finishing),
        OverlayShellStatus(phase: .upgrading, processingStatus: "Transcribing 2 of 3…"),
        OverlayShellStatus(phase: .done, processingStatus: "Session saved"),
        OverlayShellStatus(phase: .done, processingStatus: "Upgrade failed · audio retained"),
    ]

    static var height: CGFloat {
        CGFloat(states.count) * (House.Control.composer + House.hairline)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, status in
                OverlayShellHeader(status: status, callTypes: .inMemory())
                HouseDivider()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(House.ColorToken.surface)
    }
}
