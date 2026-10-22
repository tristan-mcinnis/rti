import AppKit
import RTICore
import SwiftUI
import XCTest
import HouseDesign

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

    /// Keep one hosting view alive through real Core event batches. Still
    /// images of separate view trees cannot prove that existing rows update
    /// without moving when a later batch settles or corrects an earlier row.
    func testLiveTokenSequence() throws {
        for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let pipeline = TranscriptPipeline()
            let session = SessionCoordinator.shared
            let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: startedAt)
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            UserDefaults.standard.set(
                appearanceName == .darkAqua ? RTIAppearanceMode.dark.rawValue : RTIAppearanceMode.light.rawValue,
                forKey: OverlayAppearanceDefaults.appearanceModeKey
            )
            let hosting = NSHostingView(rootView: AnyView(
                TranscriptTabView()
                    .padding(House.Spacing.lg)
                    .background(House.ColorToken.surface)
            ))
            hosting.appearance = appearance
            hosting.frame = NSRect(x: 0, y: 0, width: Self.narrowWidth, height: Self.height)
            defer {
                // An offscreen host can outlive this iteration through AppKit's
                // deferred layout work. Retire its observers before the next
                // appearance resets the shared session and replays its frames.
                hosting.rootView = AnyView(EmptyView())
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                hosting.layoutSubtreeIfNeeded()
            }

            func word(_ text: String, _ speaker: Int, _ start: Int, final: Bool) -> SonioxWord {
                SonioxWord(text: text, startMs: start, endMs: start + 100, speaker: speaker,
                           confidence: 1, isFinal: final, translationStatus: "none", language: nil, sourceLanguage: nil)
            }
            func publish(_ words: [SonioxWord], channel: String = "system", frame: String) throws -> (pixels: Data, prefix: Data) {
                let changed = pipeline.process(words: words, channel: channel)
                session.seedForRenderProof(
                    entries: pipeline.liveEntries,
                    interim: pipeline.interimLine,
                    interimSegments: pipeline.interimSegments,
                    transcriptChanged: changed,
                    phase: .recording,
                    startedAt: startedAt
                )
                return try captureSequenceFrame(hosting, appearance: appearance, name: "transcript-sequence-\(frame)-\(suffix)")
            }

            _ = try publish([word("Hello", 1, 0, final: false)], frame: "01-first-interim")
            XCTAssertTrue(session.liveEntries.isEmpty)
            XCTAssertFalse(session.interimSegments.isEmpty)
            _ = try publish([word("Hello", 1, 0, final: true), word(", world!", 1, 100, final: false)], frame: "02-punctuation-interim")
            let settled = try publish([
                word(",", 1, 100, final: true), word(" world", 1, 200, final: true), word("!", 1, 300, final: true),
            ], frame: "03-english-final")
            XCTAssertEqual(LiveTranscriptPresentation.rows(from: pipeline.liveEntries, showTranslations: false).first?.original, "Hello, world!")

            let cjkInterim = try publish([word("你好", 2, 2_000, final: false)], frame: "04-cjk-interim")
            let cjkMixed = try publish([
                word("你好", 2, 2_000, final: true), word("世界。", 2, 2_100, final: false),
            ], frame: "05-cjk-mixed")
            let cjkPunctuation = try publish([
                word("世界", 2, 2_100, final: true), word("。", 2, 2_200, final: false),
            ], frame: "06-cjk-punctuation")
            let cjkFinal = try publish([word("。", 2, 2_200, final: true)], frame: "07-cjk-final")
            XCTAssertEqual(LiveTranscriptPresentation.rows(from: pipeline.liveEntries, showTranslations: false).last?.original, "你好世界。")
            for frame in [cjkInterim, cjkMixed, cjkPunctuation, cjkFinal] {
                XCTAssertEqual(frame.prefix, settled.prefix, "Settled first-row pixels moved while a later speaker's words settled")
            }

            _ = try publish([
                word("The ", 3, 4_000, final: true), word("pilot.", 3, 4_100, final: false),
            ], frame: "08-provider-trailing-space")
            _ = try publish([word("pilot.", 3, 4_100, final: true)], frame: "09-trailing-space-final")
            let beforeCorrection = try publish([
                word("We agree on the design", 4, 6_000, final: true), word("A new topic.", 5, 10_000, final: true),
            ], frame: "10-before-late-correction")
            let priorEntries = pipeline.liveEntries
            let priorRows = LiveTranscriptPresentation.rows(from: priorEntries, showTranslations: false)
            let corrected = try publish([
                word("We agree on the design today.", 1, 6_050, final: true),
            ], channel: "mic", frame: "11-late-correction")
            let correctedRows = LiveTranscriptPresentation.rows(from: pipeline.liveEntries, showTranslations: false)
            XCTAssertEqual(pipeline.liveEntries.count, priorEntries.count)
            XCTAssertEqual(pipeline.liveEntries.last?.id, priorEntries.last?.id)
            XCTAssertEqual(correctedRows.map(\.id), priorRows.map(\.id))
            XCTAssertEqual(correctedRows[3].original, "We agree on the design today.")
            XCTAssertNotEqual(corrected.pixels, beforeCorrection.pixels, "A final revision must refresh text even when count and last ID are unchanged")
            XCTAssertEqual(corrected.prefix, settled.prefix, "The unchanged first row moved after a delayed final")
        }
    }

    private func captureSequenceFrame(
        _ hosting: NSHostingView<AnyView>,
        appearance: NSAppearance,
        name: String
    ) throws -> (pixels: Data, prefix: Data) {
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
        }
        var captured: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            captured = bitmap
        }
        let bitmap = try XCTUnwrap(captured)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: RenderProofHarness.outputDirectory.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(png.count, 2_000)

        // This short fixture fits without scrolling. The top region contains
        // the toolbar and the complete first run, but no changing second run.
        let prefixHeight = House.Control.railRow + House.Control.input + House.Spacing.lg
        let scale = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        let image = try XCTUnwrap(bitmap.cgImage)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(prefixHeight) * scale)))
        let prefix = NSBitmapImageRep(cgImage: crop)
        return (
            Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh),
            Data(bytes: try XCTUnwrap(prefix.bitmapData), count: prefix.bytesPerRow * prefix.pixelsHigh)
        )
    }

    // MARK: - Archived (Sessions window)

    private func archiveModel() async throws -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            contentSearch: nil,
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
