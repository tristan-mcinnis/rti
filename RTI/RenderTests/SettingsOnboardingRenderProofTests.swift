import AppKit
import RTICore
import SwiftUI
import XCTest

/// Package E proofs: the settings window (each pane, the rail search, the
/// footer), the welcome window (empty, keys saved, all set), and the
/// Meeting Brief window (rail hidden and shown, search, empty). PNG
/// prefixes `settings-`, `onboarding-`, `brief-`.
///
/// Briefs come from invented files written into the fixture vault's
/// `meetings/briefs/`; the welcome window runs on a fixed state and the
/// Logs pane on invented lines, so none of these read the real vault,
/// real meetings, the credentials file, or the privacy grants.
final class SettingsOnboardingRenderProofTests: RenderProofTestCase {
    private let settingsSize = CGSize(width: House.Layout.settingsWidth, height: House.Layout.settingsHeight)
    private let briefSize = CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)

    override func setUp() async throws {
        try await super.setUp()
        try FixtureBriefs.install()
    }

    // MARK: - Settings

    func testSettingsEachPane() throws {
        for pane in SettingsView.SettingsTab.allCases {
            try renderBothAppearances(
                name: "settings-pane-\(pane.rawValue)",
                size: settingsSize,
                view: SettingsView(onClose: {}, initialSection: pane, logsFixture: FixtureLogs.fixture, modeStore: ModeStore.inMemory())
            )
        }
    }

    /// The whole General pane at once, so every card can be read.
    func testSettingsGeneralFullLength() throws {
        try renderBothAppearances(
            name: "settings-pane-general-full",
            size: CGSize(width: House.Layout.settingsWidth, height: House.Layout.settingsHeight * 4),
            view: SettingsView(onClose: {}, initialSection: .general, modeStore: ModeStore.inMemory())
        )
    }

    /// "micro" keeps General only (a keyword match), and the pane follows.
    func testSettingsSearchInRail() throws {
        try renderBothAppearances(
            name: "settings-search",
            size: settingsSize,
            view: SettingsView(onClose: {}, navigation: SettingsNavigation(pane: .general, query: "micro"), modeStore: ModeStore.inMemory())
        )
        try renderBothAppearances(
            name: "settings-search-none",
            size: settingsSize,
            view: SettingsView(onClose: {}, navigation: SettingsNavigation(pane: .about, query: "zebra"), modeStore: ModeStore.inMemory())
        )
    }

    func testSettingsPaneKeysAreOneToEight() {
        XCTAssertEqual(SettingsView.SettingsTab.allCases.map(\.number), Array(1...8))
        XCTAssertEqual(SettingsView.SettingsTab.about.number, 8)
        let hits = SettingsSearch.filter(SettingsView.SettingsTab.allCases.map(\.searchPane), query: "micro")
        XCTAssertEqual(hits.map(\.id), ["general"])
    }

    // MARK: - Onboarding

    func testOnboardingEmpty() throws {
        try renderOnboarding("onboarding-empty", OnboardingView.Fixture())
    }

    func testOnboardingKeysSaved() throws {
        try renderOnboarding("onboarding-keys-saved", OnboardingView.Fixture(
            soniox: "fixture-soniox-key-0000",
            assistantKey: "fixture-assistant-key-0000",
            keysSaved: true
        ))
    }

    func testOnboardingAllSet() throws {
        try renderOnboarding("onboarding-all-set", OnboardingView.Fixture(
            soniox: "fixture-soniox-key-0000",
            assistantKey: "fixture-assistant-key-0000",
            keysSaved: true,
            microphone: .granted,
            screenRecording: .granted
        ))
    }

    func testOnboardingMicrophoneDenied() throws {
        try renderOnboarding("onboarding-mic-denied", OnboardingView.Fixture(
            soniox: "fixture-soniox-key-0000",
            assistantKey: "fixture-assistant-key-0000",
            keysSaved: true,
            microphone: .denied
        ))
    }

    func testOnboardingCopyHasNoEmDash() {
        let copy = [OnboardingView.summary] + OnboardingView.lines.map(\.text)
        for line in copy {
            XCTAssertFalse(line.contains("\u{2014}"), line)
        }
        XCTAssertTrue(OnboardingView.lines.contains { $0.text.hasPrefix("⌘\\") }, "RTI keeps ⌘\\ as its show or hide key")
    }

    private func renderOnboarding(_ name: String, _ fixture: OnboardingView.Fixture) throws {
        try renderBothAppearances(
            name: name,
            size: OnboardingWindowController.size,
            view: OnboardingView(onDone: {}, fixture: fixture)
        )
    }

    // MARK: - Meeting Brief

    func testBriefRailHidden() throws {
        let model = MeetingBriefModel(railVisible: false)
        model.reload()
        XCTAssertEqual(model.openBrief?.displayTitle, "Northwind Onboarding", "today's brief opens first")
        try renderBothAppearances(name: "brief-rail-hidden", size: briefSize, view: MeetingBriefView(model: model))
    }

    func testBriefRailShown() throws {
        let model = MeetingBriefModel(railVisible: true)
        model.reload()
        XCTAssertEqual(model.sections.map(\.title), ["Today", "Upcoming", "Earlier"])
        model.railIndex = 1
        try renderBothAppearances(name: "brief-rail-shown", size: briefSize, view: MeetingBriefView(model: model))
    }

    func testBriefSearch() throws {
        let model = MeetingBriefModel(railVisible: true)
        model.reload()
        model.query = "plan"
        XCTAssertEqual(model.sections.map(\.title), ["Results"])
        try renderBothAppearances(name: "brief-search", size: briefSize, view: MeetingBriefView(model: model))
    }

    func testBriefAtMinimumSize() throws {
        let model = MeetingBriefModel(railVisible: true)
        model.reload()
        try renderBothAppearances(
            name: "brief-minimum",
            size: CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight),
            view: MeetingBriefView(model: model)
        )
    }

    func testBriefEmpty() throws {
        try FixtureBriefs.remove()
        defer { try? FixtureBriefs.install() }
        let model = MeetingBriefModel(railVisible: true)
        model.reload()
        XCTAssertNil(model.openBrief)
        try renderBothAppearances(name: "brief-empty", size: briefSize, view: MeetingBriefView(model: model))
    }

    func testBriefEscapePopsSearchThenRail() {
        let model = MeetingBriefModel(railVisible: true)
        model.reload()
        model.query = "north"
        XCTAssertTrue(model.escape())
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.isRailVisible)
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isRailVisible)
        XCTAssertFalse(model.escape(), "a stray esc never closes the window")
    }
}

// MARK: - Fixtures

/// Invented pre-meeting briefs in the fixture vault's `meetings/briefs/`,
/// dated around the day the proof runs.
@MainActor
private enum FixtureBriefs {
    static let briefs: [(daysFromToday: Int, slug: String, body: String)] = [
        (0, "northwind-onboarding-prep", """
        # Northwind onboarding: prep

        **When:** today, 15:00 · **With:** the Northwind product team

        ## What they want from this call

        - A decision on the guided tour for the first release.
        - A date for the first-screen drop-off readout.

        ## Where we left it

        The team leaned toward shipping without the tour and measuring drop-off on the first screen. Design has not seen the decision note yet.

        ## Questions to ask

        1. Who sets the drop-off threshold that brings the tour back?
        2. Is point-one a real commitment, with a date?
        3. What does design need before Thursday?
        """),
        (1, "fabrikam-loyalty-research-prep", """
        # Fabrikam loyalty research: prep

        Four interviews on the loyalty card. Focus on why people stop using it.

        - Weekly sign-in came up twice last round.
        - Ask about the coffee counter, not the app.
        """),
        (-3, "contoso-store-pilot-prep", """
        # Contoso store pilot: prep

        The pickup counter moves to the front before the pilot. Confirm the staff rota.
        """),
        (-10, "quarterly-planning-prep", """
        # Quarterly planning: prep

        Three goals for next quarter. Bring last quarter's numbers.
        """),
    ]

    static var directory: URL? { VaultPaths.briefsDirectory() }

    static func install(now: Date = Date()) throws {
        guard let directory, let root = FixtureVault.root,
              directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path)
        else {
            XCTFail("the briefs folder is not inside the fixture vault")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"
        for brief in briefs {
            let day = calendar.date(byAdding: .day, value: brief.daysFromToday, to: now) ?? now
            let text = """
            ---
            title: "Invented fixture brief"
            type: brief
            ---
            \(brief.body)

            """
            try text.write(
                to: directory.appendingPathComponent("\(stamp.string(from: day))-\(brief.slug).md"),
                atomically: true,
                encoding: .utf8
            )
        }
        // The real folder has a README; the list must skip it.
        try "# Briefs\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    static func remove() throws {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// Invented log lines for the Logs pane.
@MainActor
private enum FixtureLogs {
    static var fixture: LogsView.Fixture {
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 4, of: Date()) ?? Date()
        let lines: [(TimeInterval, String, String)] = [
            (0, "audio", "Mic bound to the built-in microphone (48 kHz)."),
            (1.2, "soniox", "Live transcription connected."),
            (2.5, "audio", "System audio: process tap started."),
            (64, "llm", "Assist answered in 2.1 s (DeepSeek)."),
            (121, "analysis", "Notes pass 1 done: 2 slices."),
            (402, "soniox", "Reconnected after 1 retry."),
        ]
        return LogsView.Fixture(
            entries: lines.map { offset, category, message in
                AppLog.Entry(timestamp: start.addingTimeInterval(offset), level: .info, category: category, message: message)
            }
        )
    }
}
