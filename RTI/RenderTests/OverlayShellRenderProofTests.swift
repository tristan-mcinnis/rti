import AppKit
import RTICore
import SwiftUI
import XCTest

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
        let keys = [
            AnalysisSettingsDefaults.notesEnabledKey,
            AnalysisSettingsDefaults.guideEnabledKey,
            AnalysisSettingsDefaults.findingsEnabledKey,
            AnalysisSettingsDefaults.autoAssistEnabledKey,
        ]
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
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
                    OverlayShellHeader(status: OverlayShellStatus(phase: .idle))
                    HouseDivider()
                    OverlayShellHeader(status: OverlayShellStatus(phase: .recording))
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

    func testNotesReady() throws {
        SessionCoordinator.shared.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .done, startedAt: nil)
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        try renderPanel(
            "shell-notes-ready",
            widths: [Self.standardWidth, Self.minimumWidth],
            status: OverlayShellStatus(phase: .done, summaryReady: true, processingStatus: "Notes ready")
        )
    }

    /// Every opt-in tab on, so the row shows all seven.
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

    func testTranscriptEmpty() throws {
        try renderPanel("shell-transcript-empty", widths: [Self.standardWidth], tab: .transcript)
    }

    func testEmptyNotesGuideAndIntel() throws {
        enableEveryTab()
        seedRecording(entries: [])
        try renderPanel("shell-notes-empty", widths: [Self.standardWidth, Self.minimumWidth], tab: .notes)
        try renderPanel("shell-guide-empty", widths: [Self.standardWidth], tab: .guide)
        try renderPanel("shell-intel-empty", widths: [Self.standardWidth], tab: .findings)
        try renderPanel("shell-auto-empty", widths: [Self.standardWidth], tab: .auto)
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

    func testModeChooser() throws {
        seedRecording()
        OverlayShellModel.shared.chooser = .mode
        try renderPanel("shell-chooser-mode", widths: [Self.minimumWidth])
    }

    func testKeptOnTop() throws {
        seedRecording()
        OverlayWindowChrome.shared.isKeptOnTop = true
        try renderPanel("shell-kept-on-top", widths: [Self.standardWidth])
    }

    // MARK: - Seams

    /// The ⌘1…⌘7 order in RTICore is the tab order the overlay draws.
    func testTabShortcutsMatchTheTabs() {
        XCTAssertEqual(OverlayTab.allCases.map(\.rawValue), OverlayTabShortcut.order)
        XCTAssertEqual(OverlayTab.setup.shortcutLabel, "⌘1")
        XCTAssertEqual(OverlayTab.findings.shortcutLabel, "⌘7")
    }

    /// Each session phase maps to the header's phase of the same name.
    func testPhaseMapping() {
        let phases: [SessionCoordinator.Phase] = [.idle, .recording, .paused, .finishing, .summarizing, .done]
        XCTAssertEqual(phases.map(\.livePhase.rawValue), ["idle", "recording", "paused", "finishing", "summarizing", "done"])
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
        for key in [
            AnalysisSettingsDefaults.notesEnabledKey,
            AnalysisSettingsDefaults.guideEnabledKey,
            AnalysisSettingsDefaults.findingsEnabledKey,
            AnalysisSettingsDefaults.autoAssistEnabledKey,
        ] {
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
                view: OverlayPanelView(statusOverride: status)
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
        OverlayShellStatus(phase: .summarizing, processingStatus: "Transcribing 2 of 3…"),
        OverlayShellStatus(phase: .done, summaryReady: true, processingStatus: "Notes ready"),
        OverlayShellStatus(phase: .done, processingStatus: "Upgrade failed · audio retained"),
    ]

    static var height: CGFloat {
        CGFloat(states.count) * (House.Control.composer + House.hairline)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, status in
                OverlayShellHeader(status: status)
                HouseDivider()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(House.ColorToken.surface)
    }
}
