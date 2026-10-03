import AppKit
import RTICore
import SwiftUI
import XCTest

/// The transcript, live and archived: several speakers on both legs, runs of
/// the same speaker, a note, and interim text still settling. Narrow (the
/// overlay's 600 minimum, the Sessions window's minimum) and wide. PNG prefix
/// `transcript-`.
final class TranscriptRenderProofTests: RenderProofTestCase {
    private static let narrowWidth = OverlayAppearanceDefaults.widthRange.lowerBound
    private static let wideWidth = OverlayAppearanceDefaults.widthRange.upperBound
    private static let height: Double = 600

    override func tearDown() async throws {
        LiveTranscriptList.startsFollowing = true
        MeetingContextStore.shared.resetAfterSession()
        SpeakerNameStore.shared.reset()
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    /// A call: the mic leg (`self`) and two remote voices on the system leg.
    static var meeting: [LiveEntry] { [
        RenderFixtures.liveEntry("self", "Thanks for making time. I want to leave today with a decision on the onboarding scope.", 723_000),
        RenderFixtures.liveEntry("self", "Everything else can wait for Thursday.", 729_000),
        RenderFixtures.liveEntry("remote_1", "Sure. The short version: if we keep the guided tour, the launch slips by a sprint.", 735_000),
        RenderFixtures.liveEntry("remote_2", "I'd rather ship without the tour and measure drop-off on the first screen.", 747_000),
        RenderFixtures.liveEntry("remote_2", "We can add it back in point-one if the numbers say so.", 753_000),
        RenderFixtures.liveEntry("note", "Leaning: ship without the tour", 758_000),
        RenderFixtures.liveEntry("self", "That works for me. Can you own the decision note so design isn't surprised on Thursday?", 761_000),
        RenderFixtures.liveEntry("remote_1", "Yes, I'll write it up today.", 776_000),
    ] }

    static let interim = "remote_1: and I'll tag the design channel so they see it before"

    private func seedLive() {
        SessionCoordinator.shared.seedForRenderProof(
            entries: Self.meeting,
            interim: Self.interim,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-780)
        )
    }

    private func renderOverlay(_ name: String, width: Double) throws {
        try renderBothAppearances(
            name: name,
            size: CGSize(width: width, height: Self.height),
            view: OverlayPanelView(modes: ModeStore.inMemory())
                .onAppear { NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue) }
        )
    }

    /// Interim words from two legs at once: the last speaker's continue
    /// their run, the mic wearer's open a bubble below it.
    func testLiveNarrow() throws {
        // The second half of the meeting, so the settling tail fits the frame.
        SessionCoordinator.shared.seedForRenderProof(
            entries: Array(Self.meeting.dropFirst(3)),
            interim: "self: Perfect, thanks  " + Self.interim,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-780)
        )
        try renderOverlay("transcript-live-narrow", width: Self.narrowWidth)
    }

    /// A named remote speaker, as after a rename or an attendee pick; the
    /// other remote voice offers the meeting's invitees as its name menu.
    func testLiveWideNamed() throws {
        MeetingContextStore.shared.selectCalendarMeeting(CalendarMeeting(
            id: "proof", title: "Onboarding scope", startDate: Date(), endDate: Date().addingTimeInterval(1800),
            attendees: [.init(name: "Sam", isCurrentUser: true), .init(name: "Priya Shah"), .init(name: "Sam Lee")]
        ))
        SpeakerNameStore.shared.rename("remote_1", to: "Priya Shah")
        seedLive()
        try renderOverlay("transcript-live-wide", width: Self.wideWidth)
    }

    /// Scrolled up from the latest line: following stops and "Jump to
    /// latest" appears.
    func testLiveScrolledUp() throws {
        LiveTranscriptList.startsFollowing = false
        // Twice the meeting, so the list is taller than the window.
        let later = Self.meeting.map {
            RenderFixtures.liveEntry($0.speakerId, $0.text, $0.startMs + 60_000)
        }
        SessionCoordinator.shared.seedForRenderProof(
            entries: Self.meeting + later,
            interim: Self.interim,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-840)
        )
        try renderOverlay("transcript-live-scrolled-up", width: Self.narrowWidth)
    }

    /// A long run by one speaker reads as paragraphs under one label; the
    /// interim words continue the open paragraph only.
    func testLiveLongRun() throws {
        let sentences = [
            "Let me walk through the numbers from the pilot before we decide anything.",
            "In the first week about four in ten new users left on the first screen, and most of them never touched the guided tour at all.",
            "The ones who finished the tour stayed longer, but they were also the people who came in from the sales demo, so they were already keen.",
            "That makes me think the tour is not what keeps people; it is who they are when they arrive.",
            "So my proposal is to ship without it, watch the first-screen drop-off for two weeks, and only bring the tour back if the number gets worse.",
            "I also want design to try a lighter hint on the empty state, because that is where people stall today.",
            "If that hint works, we may never need the full tour again.",
        ]
        let entries = [RenderFixtures.liveEntry("self", "Before you go on, can you share the pilot numbers?", 700_000)]
            + sentences.enumerated().map { index, text in
                RenderFixtures.liveEntry("remote_1", text, 705_000 + index * 6_000)
            }
        SessionCoordinator.shared.seedForRenderProof(
            entries: entries,
            interim: "remote_1: and then we can talk about the Thursday review",
            phase: .recording,
            startedAt: Date().addingTimeInterval(-780)
        )
        try renderOverlay("transcript-live-long-run", width: Self.narrowWidth)
    }

    // MARK: - Archived (Sessions window)

    private func archiveModel() async throws -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            contentSearch: nil,
            generateTitle: nil,
            persistGeneratedTitle: { _, _ in XCTFail("a proof must never write a title") },
            now: { Date() }
        ))
        await model.reload()
        model.setRailVisible(false, remember: false)
        let row = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Onboarding") })
        model.open(row.id)
        model.selectFile(named: "transcript")
        return model
    }

    func testArchivedWide() async throws {
        let model = try await archiveModel()
        try renderBothAppearances(
            name: "transcript-archive-wide",
            size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight),
            view: SessionsBrowserView(model: model)
        )
    }

    func testArchivedNarrow() async throws {
        let model = try await archiveModel()
        try renderBothAppearances(
            name: "transcript-archive-narrow",
            size: CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight),
            view: SessionsBrowserView(model: model)
        )
    }
}
