import Foundation
import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// The Prepare page: call type, project, guide (research), audio, then one
/// "More options" disclosure. PNGs are `setup-*`, wide (1000 pt) and narrow
/// (560 pt), dark and light. Only invented fixtures: the fixture vault's
/// project, an invented guide and an invented calendar event.
final class SetupRenderProofTests: RenderProofTestCase {
    private let guideJSON = """
    {"title":"Storage habits","sections":[
      {"id":"S1","title":"Everyday storage","minutes":12,"questions":[
        {"qid":"S1Q1","en":"Where do you keep the things you use every day?","zh":"你把日常用品放在哪里？","probes":[]},
        {"qid":"S1Q2","en":"What makes an item hard to find?","zh":"什么东西最难找到？","probes":[]}]},
      {"id":"S2","title":"A recent change","minutes":3,"questions":[
        {"qid":"S2Q1","en":"What have you moved recently?","zh":"最近移动过哪些东西？","probes":[]}]}
    ]}
    """

    private let widths: [(String, CGFloat)] = [("wide", 1000), ("narrow", 560)]
    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
        suiteName = "rti.renderproof.setup.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        suite.removePersistentDomain(forName: suiteName)
        MeetingContextStore.shared.clearWorkstream()
        MeetingContextStore.shared.clearCalendarMeeting()
        CalendarMeetingStore.shared.seedForRenderProof(nil)
        GuidePreparation.shared.reset()
        ResearchCodebookController.shared.seedText = ""
        SessionMarkers.shared.prepared = nil
        SessionMarkers.shared.preparedProjectID = nil
        try await super.tearDown()
    }

    private func page(_ callType: CallType, width: CGFloat) -> some View {
        SetupTabView(callTypes: .inMemory(callType), defaults: suite)
            // The Live page's tab padding (OverlayPanelView.tabContentPadding).
            .padding(.horizontal, House.Spacing.lg).padding(.top, House.Spacing.xs)
            .frame(width: width)
            .background(House.ColorToken.surfaceRaised)
    }

    private func fixtureProject() throws -> VaultItem {
        try XCTUnwrap(VaultWorkstreamStore.projects().first { $0.name.lowercased().contains("northwind") },
                      "The fixture vault carries the Northwind project")
    }

    private func prepareResearch() throws {
        let project = try fixtureProject()
        MeetingContextStore.shared.selectWorkstream(project)
        let guide = try GuideDocument.parse(Data(guideJSON.utf8))
        GuidePreparation.shared.setGuide(guide, url: URL(fileURLWithPath: "/fixture/dg-questions.json"), parsedSourceJSON: nil)
        GuidePreparation.shared.groupText = "G1"
        let now = Date()
        let event = CalendarMeeting(id: "fixture-event", title: "Storage habits group 1", startDate: now.addingTimeInterval(-300),
                                    endDate: now.addingTimeInterval(3300), attendees: [.init(name: "Moderator")],
                                    calendarName: "Work", calendarSource: "Fixture")
        CalendarMeetingStore.shared.seedForRenderProof([event], suggestion: event)
    }

    func testClientCallWithNoProject() throws {
        for (label, width) in widths {
            try checkGrid(.client, width: width, height: 560)
            try renderBothAppearances(name: "setup-client-\(label)", size: CGSize(width: width, height: 560),
                                      view: page(.client, width: width))
        }
    }

    func testResearchWithProjectAndGuide() throws {
        try prepareResearch()
        for (label, width) in widths {
            let frames = try checkGrid(.research, width: width, height: 720)
            for name in ["text.project", "text.calendarLine", "text.guide", "text.status",
                         "title.Codebook and stimulus", "title.More options"]
            {
                XCTAssertNotNil(frames[name], "\(name) missing at \(label)")
            }
            try renderBothAppearances(name: "setup-research-\(label)", size: CGSize(width: width, height: 720),
                                      view: page(.research, width: width))
        }
    }

    func testResearchWithMoreOptionsAndCodebookOpen() throws {
        try prepareResearch()
        suite.set(true, forKey: SetupPageSettings.moreOptionsExpandedKey)
        suite.set(true, forKey: SetupPageSettings.researchExtrasExpandedKey)
        ResearchCodebookController.shared.seedText = "Morning Cup 晨杯\n洗起来麻烦"
        var package = StimulusPackage(revision: "", version: "Manual", items: [])
        package.addManual(label: "Board A", page: 2)
        SessionMarkers.shared.preparedProjectID = try fixtureProject().url.path
        SessionMarkers.shared.prepared = package
        for (label, width) in widths {
            let frames = try checkGrid(.research, width: width, height: 1640)
            for name in ["text.seeds", "field.seeds", "text.stimulus", "field.stimulus", "text.speakers"] {
                XCTAssertNotNil(frames[name], "\(name) missing at \(label)")
            }
            // The stimulus row sits under the seed editor, on the same edges.
            if let seeds = frames["field.seeds"], let stimulus = frames["field.stimulus"] {
                XCTAssertEqual(stimulus.minX, seeds.minX, accuracy: 0.5, "Stimulus row off the seed editor's edge at \(label)")
                XCTAssertEqual(stimulus.height, House.Control.chip, accuracy: 0.5, "Stimulus field height at \(label)")
            }
            // The Speakers sentence is the card's footnote, under the card.
            if let speakers = frames["text.speakers"], let header = frames["edge.section.Speakers"] {
                XCTAssertGreaterThan(speakers.minY, header.maxY + House.Control.row, "Speakers sentence sits above its card")
            }
            try renderBothAppearances(name: "setup-research-open-\(label)", size: CGSize(width: width, height: 1640),
                                      view: page(.research, width: width))
        }
    }

    /// Clicking a disclosure writes its own key in the injected suite, and a
    /// new page built on that suite opens with it.
    func testDisclosureStateIsKeptPerKey() throws {
        XCTAssertNotEqual(SetupPageSettings.moreOptionsExpandedKey, SetupPageSettings.researchExtrasExpandedKey)
        let standardBefore = UserDefaults.standard.object(forKey: SetupPageSettings.moreOptionsExpandedKey) as? Bool
        XCTAssertNil(suite.object(forKey: SetupPageSettings.moreOptionsExpandedKey))

        let closed = try layout(.client, width: 1000, height: 900)
        XCTAssertNil(closed.frames["edge.section.Live aids"], "More options starts closed")
        try click("title.More options", in: closed)

        XCTAssertEqual(suite.object(forKey: SetupPageSettings.moreOptionsExpandedKey) as? Bool, true)
        XCTAssertNil(suite.object(forKey: SetupPageSettings.researchExtrasExpandedKey), "Only the pressed disclosure is written")
        XCTAssertEqual(UserDefaults.standard.object(forKey: SetupPageSettings.moreOptionsExpandedKey) as? Bool, standardBefore,
                       "The page wrote the app's own defaults")

        let reopened = try layout(.client, width: 1000, height: 900)
        XCTAssertNotNil(reopened.frames["edge.section.Live aids"], "A new page did not read the kept state")
        suite.set(false, forKey: SetupPageSettings.moreOptionsExpandedKey)
        let closedAgain = try layout(.client, width: 1000, height: 900)
        XCTAssertNil(closedAgain.frames["edge.section.Live aids"])
    }

    // MARK: - Layout checks

    private var windows: [NSWindow] = []

    @MainActor private final class FrameBox {
        var frames: [String: CGRect] = [:]
    }

    /// Lay the page out with its layout marks on and return where it put
    /// each marked view, in the column's own space.
    private func layout(_ callType: CallType, width: CGFloat, height: CGFloat)
        throws -> (frames: [String: CGRect], hosting: NSHostingView<AnyView>)
    {
        SetupTabView.reportsLayout = true
        defer { SetupTabView.reportsLayout = false }
        let box = FrameBox()
        let root = AnyView(page(callType, width: width)
            .onPreferenceChange(SetupLayoutKey.self) { frames in
                MainActor.assumeIsolated { box.frames = frames }
            })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 3000))
        // A nonactivating panel ordered behind everything and off every
        // screen, as the title-row click proof hosts the header: the page can
        // take a real click and nothing reaches the user's screen.
        _ = NSApplication.shared
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.hasShadow = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        settle(hosting)
        windows.append(window)
        return (box.frames, hosting)
    }

    private func settle(_ view: NSView) {
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Click the middle of a marked view with real mouse events, as a
    /// person would.
    private func click(_ name: String, in layout: (frames: [String: CGRect], hosting: NSHostingView<AnyView>)) throws {
        let target = try XCTUnwrap(layout.frames[name + "@window"], "No \(name) on the page")
        let hosting = layout.hosting
        let window = try XCTUnwrap(hosting.window)
        let local = hosting.isFlipped ? NSPoint(x: target.midX, y: target.midY)
            : NSPoint(x: target.midX, y: hosting.bounds.height - target.midY)
        let point = hosting.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        settle(hosting)
    }

    /// The grid: section labels and controls on 0; every line of text, quiet
    /// line and disclosure title on `SetupGrid.textColumn`; nothing past the
    /// column's right edge; the page fits the proof's height.
    @discardableResult
    private func checkGrid(_ callType: CallType, width: CGFloat, height: CGFloat,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [String: CGRect]
    {
        let frames = try layout(callType, width: width, height: height).frames
        let page = try XCTUnwrap(frames["page"], "No layout marks reported", file: file, line: line)
        XCTAssertGreaterThan(frames.count, 4, "Too few layout marks", file: file, line: line)
        // The proof adds `xs` above the page; the page must end inside it.
        XCTAssertLessThanOrEqual(page.maxY + House.Spacing.xs, height, "Page runs past the proof at \(width)", file: file, line: line)
        for (name, frame) in frames where name != "page" && !name.hasSuffix("@window") {
            XCTAssertLessThanOrEqual(frame.maxX, page.width + 0.5, "\(name) runs past the column at \(width)", file: file, line: line)
            if name.hasPrefix("edge.") {
                XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "\(name) off the page edge at \(width)", file: file, line: line)
            } else {
                XCTAssertEqual(frame.minX, SetupGrid.textColumn, accuracy: 0.5,
                               "\(name) at x \(frame.minX), not the text column, at \(width)", file: file, line: line)
            }
        }
        return frames
    }

    func testQuietLinesSayWhatIsSet() {
        XCTAssertEqual(SetupTabView.liveStatusLine(notes: true, auto: true, guideNotes: true),
                       "Notes on · Auto on · Guide notes on. Change in More options.")
        XCTAssertEqual(SetupTabView.liveStatusLine(notes: false, auto: nil, guideNotes: false),
                       "Notes off. Change in More options.")
        XCTAssertEqual(SetupTabView.researchExtrasSummary(seeds: 0, stimulusItems: 0), "Optional")
        XCTAssertEqual(SetupTabView.researchExtrasSummary(seeds: 2, stimulusItems: 1), "2 words to watch · 1 stimulus item")
    }

    /// Plain seed lines become names; the power-user `type | name` syntax
    /// still files a typed code.
    func testPlainAndPipeSeedLinesBothWork() {
        var book = ResearchCodebook()
        ResearchCodebookStore.seed("Morning Cup 晨杯", into: &book)
        ResearchCodebookStore.seed("client | Brand Z", into: &book)
        XCTAssertTrue(book.cards.contains { $0.name.contains("Morning Cup") })
        XCTAssertTrue(book.cards.contains { $0.name == "Brand Z" && $0.type == .brand && $0.pinned })
    }
}
