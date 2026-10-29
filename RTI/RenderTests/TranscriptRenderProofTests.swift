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
    private var interactionWindows: [ObjectIdentifier: NSPanel] = [:]

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

    /// A remote voice heard on both legs, cut into batches at different
    /// points: one speaker's turn with no split word and no echoed line.
    func testLiveEchoMeeting() throws {
        let pipeline = TranscriptPipeline()
        EchoMeetingFixture.replay(into: pipeline)
        SessionCoordinator.shared.seedForRenderProof(
            entries: pipeline.liveEntries,
            interim: pipeline.interimLine,
            interimSegments: pipeline.interimSegments,
            phase: .recording,
            startedAt: Date().addingTimeInterval(-30)
        )
        try renderOverlay("transcript-live-echo", width: Self.narrowWidth)
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

    /// The words do not change here, only the finalization frontier. Read the
    /// changing run from the pixels, rather than checking an unrelated prefix.
    func testFinalizingLongRunKeepsVisibleWordsInPlace() async throws {
        for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let pipeline = TranscriptPipeline()
            let session = SessionCoordinator.shared
            session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: Date())
            let (hosting, appearance) = try acceptanceHost(appearanceName)
            defer { retireAcceptanceHost(hosting) }
            let prefix = String(repeating: "word ", count: 90)

            func publish(_ words: [SonioxWord]) {
                let changed = pipeline.process(words: words, channel: "system")
                session.seedForRenderProof(
                    entries: pipeline.liveEntries,
                    interim: pipeline.interimLine,
                    interimSegments: pipeline.interimSegments,
                    transcriptChanged: changed,
                    phase: .recording,
                    startedAt: Date()
                )
            }

            publish([acceptanceWord(prefix, speaker: 1, at: 0, final: true),
                     acceptanceWord("finished. Tail stays here.", speaker: 1, at: 100, final: false)])
            let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-paragraph-before-\(suffix)")
            let beforeAnchor = try textAnchor("Tail stays here", in: before)

            publish([acceptanceWord("finished.", speaker: 1, at: 100, final: true),
                     acceptanceWord(" Tail stays here.", speaker: 1, at: 200, final: false)])
            let partial = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-paragraph-partial-\(suffix)")
            let partialAnchor = try textAnchor("Tail stays here", in: partial)
            XCTAssertEqual(beforeAnchor.midY * Self.height, partialAnchor.midY * Self.height, accuracy: 2,
                           "Identical visible words moved when the preceding sentence became final")

            publish([acceptanceWord(" Tail stays here.", speaker: 1, at: 200, final: true)])
            let after = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-paragraph-final-\(suffix)")
            let afterAnchor = try textAnchor("Tail stays here", in: after)
            XCTAssertEqual(beforeAnchor.midY * Self.height, afterAnchor.midY * Self.height, accuracy: 2,
                           "Finality alone must not introduce a paragraph gap")
        }
    }

    func testEarlierPendingVoiceAppearsBeforeLaterFinalVoice() async throws {
        let pipeline = TranscriptPipeline()
        let session = SessionCoordinator.shared
        session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: Date())
        let (hosting, appearance) = try acceptanceHost(.aqua)
        defer { retireAcceptanceHost(hosting) }

        pipeline.process(words: [acceptanceWord("Earlier microphone phrase.", speaker: 1, at: 1_000, final: false)], channel: "mic")
        pipeline.process(words: [acceptanceWord("Later system phrase.", speaker: 1, at: 2_000, final: true)], channel: "system")
        session.seedForRenderProof(
            entries: pipeline.liveEntries, interim: pipeline.interimLine,
            interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date()
        )
        let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-order-before")
        let earlyBefore = try textAnchor("Earlier microphone phrase", in: before)
        let lateBefore = try textAnchor("Later system phrase", in: before)
        XCTAssertGreaterThan(earlyBefore.midY, lateBefore.midY,
                             "Vision coordinates start at the bottom; earlier speech must already be above later speech")

        pipeline.process(words: [acceptanceWord("Earlier microphone phrase.", speaker: 1, at: 1_000, final: true)], channel: "mic")
        session.seedForRenderProof(
            entries: pipeline.liveEntries, interim: pipeline.interimLine,
            interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date()
        )
        let after = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-order-final")
        let earlyAfter = try textAnchor("Earlier microphone phrase", in: after)
        let lateAfter = try textAnchor("Later system phrase", in: after)
        XCTAssertEqual(earlyBefore.midY * Self.height, earlyAfter.midY * Self.height, accuracy: 2)
        XCTAssertEqual(lateBefore.midY * Self.height, lateAfter.midY * Self.height, accuracy: 2)
    }

    func testPacketBoundariesPreserveInterleavedWordOrder() async throws {
        let pipeline = TranscriptPipeline()
        let session = SessionCoordinator.shared
        session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: Date())
        let (hosting, appearance) = try acceptanceHost(.aqua)
        defer { retireAcceptanceHost(hosting) }

        func publish() {
            session.seedForRenderProof(entries: pipeline.liveEntries, interim: pipeline.interimLine,
                                      interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date())
        }
        pipeline.process(words: [
            acceptanceWord("Earlier microphone words.", speaker: 1, at: 0, final: false),
            acceptanceWord(" Later microphone words.", speaker: 1, at: 2_000, final: false),
        ], channel: "mic")
        pipeline.process(words: [acceptanceWord("Middle remote words.", speaker: 1, at: 1_000, final: true)], channel: "system")
        publish()
        let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-packet-pending")
        let labels = ["Earlier microphone words", "Middle remote words", "Later microphone words"]
        let anchors = try labels.map { try textAnchor($0, in: before) }
        XCTAssertGreaterThan(anchors[0].midY, anchors[1].midY)
        XCTAssertGreaterThan(anchors[1].midY, anchors[2].midY)

        pipeline.process(words: [
            acceptanceWord("Earlier microphone words.", speaker: 1, at: 0, final: true),
            acceptanceWord(" Later microphone words.", speaker: 1, at: 2_000, final: false),
        ], channel: "mic")
        publish()
        let partial = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-packet-partial")
        pipeline.process(words: [acceptanceWord(" Later microphone words.", speaker: 1, at: 2_000, final: true)], channel: "mic")
        publish()
        let after = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-packet-final")
        for (index, label) in labels.enumerated() {
            for frame in [partial, after] {
                let anchor = try textAnchor(label, in: frame)
                XCTAssertEqual(anchor.midY * Self.height, anchors[index].midY * Self.height, accuracy: 2)
                XCTAssertEqual(anchor.midX * Self.narrowWidth, anchors[index].midX * Self.narrowWidth, accuracy: 2)
            }
        }
    }

    /// Real Soniox packets split English words across messages. Overlapping
    /// voices must keep each phrase readable instead of alternating syllables.
    func testOverlappingProviderFragmentsStayInReadableRuns() async throws {
        let pipeline = TranscriptPipeline()
        let session = SessionCoordinator.shared
        session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: Date())
        let (hosting, appearance) = try acceptanceHost(.aqua)
        defer { retireAcceptanceHost(hosting) }
        let mic: [(String, Int)] = [("The bl", 0), ("ue lan", 200), ("tern proto", 400), ("type is ready.", 600)]
        let system: [(String, Int)] = [("A green but", 100), ("ton stays", 300), (" unchanged.", 500)]

        func publish(micFinal: Int, systemFinal: Int, previousMicFinal: Int, previousSystemFinal: Int) {
            for (channel, tokens, frontier, prior) in [("mic", mic, micFinal, previousMicFinal),
                                                      ("system", system, systemFinal, previousSystemFinal)] {
                pipeline.process(words: tokens.enumerated().compactMap { index, token in
                    index < prior ? nil : acceptanceWord(token.0, speaker: 1, at: token.1, final: index < frontier)
                }, channel: channel)
            }
            session.seedForRenderProof(entries: pipeline.liveEntries, interim: pipeline.interimLine,
                                      interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date())
        }

        publish(micFinal: 0, systemFinal: 0, previousMicFinal: 0, previousSystemFinal: 0)
        let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-overlap-pending")
        let phrases = ["blue lantern prototype is ready", "green button stays unchanged"]
        let anchors = try phrases.map { try textAnchor($0, in: before) }
        publish(micFinal: 2, systemFinal: 1, previousMicFinal: 0, previousSystemFinal: 0)
        let partial = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-overlap-partial")
        publish(micFinal: mic.count, systemFinal: system.count, previousMicFinal: 2, previousSystemFinal: 1)
        let final = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-overlap-final")
        XCTAssertEqual(session.transcriptRows.count, 2)
        for (index, phrase) in phrases.enumerated() {
            for frame in [partial, final] {
                let anchor = try textAnchor(phrase, in: frame)
                XCTAssertEqual(anchor.midY * Self.height, anchors[index].midY * Self.height, accuracy: 2)
            }
        }
    }

    func testReaderKeepsViewportAcrossUpdatesAndTabReturn() async throws {
        let session = SessionCoordinator.shared
        let entries = (0..<100).map { index in
            RenderFixtures.liveEntry(index.isMultiple(of: 2) ? "remote_1" : "remote_2",
                                     "Review marker \(index). This invented row identifies a reading position.", index * 2_000)
        }
        session.seedForRenderProof(entries: entries, interim: nil, phase: .recording, startedAt: Date())
        let (hosting, appearance) = try acceptanceHost(.aqua, windowed: true)
        hosting.rootView = AnyView(OverlayPanelView(modes: ModeStore.inMemory()))
        defer { retireAcceptanceHost(hosting) }
        settleAcceptanceHost(hosting)
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue)
        settleAcceptanceHost(hosting)
        let scroll = try XCTUnwrap(scrollViews(in: hosting).max { $0.frame.height < $1.frame.height })
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height * 3)

        // Drive the real clip view and its normal AppKit live-scroll signals.
        // No desktop input, window activation or fixture-only following flag.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settleAcceptanceHost(hosting)
        let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-reader-before")
        let marker = try XCTUnwrap(before.filter { $0.text.contains("Review marker") }.dropFirst().first)
        _ = try textAnchor("Jump to latest", in: before)

        let updated = entries + [RenderFixtures.liveEntry("remote_3", "The newest arriving phrase.", 210_000)]
        session.seedForRenderProof(entries: updated, interim: nil, phase: .recording, startedAt: Date())
        settleAcceptanceHost(hosting)
        let arrived = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-reader-arrival")
        let arrivingAnchor = try textAnchor(marker.text, in: arrived)
        // Vision's glyph boxes vary by a pixel or two; four points is still
        // well below one text line and rejects a changed reading position.
        XCTAssertEqual(arrivingAnchor.midY * Self.height, marker.boundingBox.midY * Self.height, accuracy: 4)
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.notes.rawValue)
        settleAcceptanceHost(hosting)
        let hiddenUpdate = updated + [RenderFixtures.liveEntry("remote_4", "A phrase received while the reader was hidden.", 212_000)]
        session.seedForRenderProof(entries: hiddenUpdate, interim: nil, phase: .recording, startedAt: Date())
        SpeakerNameStore.shared.rename("remote_4", to: "Taylor")
        settleAcceptanceHost(hosting)
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.assist.rawValue)
        settleAcceptanceHost(hosting)
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue)
        settleAcceptanceHost(hosting)
        XCTAssertTrue(scrollViews(in: hosting).contains { $0 === scroll }, "The reader's native scroll view was replaced")
        let after = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-reader-return")
        let returned = try textAnchor(marker.text, in: after)
        XCTAssertEqual(returned.midY * Self.height, marker.boundingBox.midY * Self.height, accuracy: 4)

        let jump = try textAnchor("Jump to latest", in: after)
        try pressAcceptanceLabel(jump, in: hosting)
        settleAcceptanceHost(hosting)
        let latest = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-reader-latest")
        _ = try textAnchor("A phrase received while the reader was hidden", in: latest)
        _ = try textAnchor("Taylor", in: latest)
        XCTAssertFalse(latest.contains { $0.text.contains("Jump to latest") })
    }

    func testPendingSpeakerNameDraftSurvivesFinalization() async throws {
        let pipeline = TranscriptPipeline()
        let session = SessionCoordinator.shared
        SpeakerNameStore.shared.reset()
        MeetingContextStore.shared.resetAfterSession()
        pipeline.process(words: [acceptanceWord("A speaker is still talking.", speaker: 1, at: 1_000, final: false)], channel: "system")
        session.seedForRenderProof(entries: [], interim: pipeline.interimLine,
                                  interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date())
        let (hosting, appearance) = try acceptanceHost(.aqua, windowed: true)
        defer { retireAcceptanceHost(hosting) }
        settleAcceptanceHost(hosting)
        let before = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-name-before")
        // The OCR label includes the adjacent timestamp. Press the speaker
        // name at the left of that observed label, using this window only.
        try pressAcceptanceLabel(textAnchor("Speaker 1", in: before), in: hosting, horizontalFraction: 0.3)
        settleAcceptanceHost(hosting)
        let window = try XCTUnwrap(hosting.window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText("Alex draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settleAcceptanceHost(hosting)
        XCTAssertEqual(editor.string, "Alex draft")
        _ = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-name-pending")

        pipeline.process(words: [acceptanceWord("A speaker is still talking.", speaker: 1, at: 1_000, final: true)], channel: "system")
        session.seedForRenderProof(entries: pipeline.liveEntries, interim: pipeline.interimLine,
                                  interimSegments: pipeline.interimSegments, phase: .recording, startedAt: Date())
        settleAcceptanceHost(hosting)
        XCTAssertTrue(window.firstResponder === editor, "Finalization took keyboard focus away from the name editor")
        XCTAssertEqual(editor.string, "Alex draft",
                       "Promoting pending text replaced the editor and lost the user's draft")
        _ = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-name-final")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        settleAcceptanceHost(hosting)
        XCTAssertEqual(SpeakerNameStore.shared.name(for: "remote_1"), "Alex draft")
    }

    func testTranslationVisibilityUsesCurrentSettingOnFirstVisitAndToggle() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: TranslationDefaults.enabledKey)
        defer {
            if let prior { defaults.set(prior, forKey: TranslationDefaults.enabledKey) }
            else { defaults.removeObject(forKey: TranslationDefaults.enabledKey) }
        }
        let pipeline = TranscriptPipeline()
        pipeline.process(words: [acceptanceWord("Original meeting sentence.", speaker: 1, at: 0, final: true)], channel: "system")
        pipeline.process(words: [SonioxWord(text: "GREEN BUTTON", startMs: 0, endMs: 0,
                                           speaker: 1, confidence: 1, isFinal: true, translationStatus: "translation",
                                           language: "en", sourceLanguage: "en")], channel: "system")
        let session = SessionCoordinator.shared
        defaults.set(true, forKey: TranslationDefaults.enabledKey)
        session.seedForRenderProof(entries: pipeline.liveEntries, interim: nil, phase: .done, startedAt: Date())
        defaults.set(false, forKey: TranslationDefaults.enabledKey)
        let (hosting, appearance) = try acceptanceHost(.aqua)
        defer { retireAcceptanceHost(hosting) }
        let firstVisit = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-translation-first-off")
        _ = try textAnchor("Original meeting sentence", in: firstVisit)
        XCTAssertFalse(firstVisit.contains { $0.text.contains("GREEN BUTTON") })

        defaults.set(true, forKey: TranslationDefaults.enabledKey)
        settleAcceptanceHost(hosting)
        let enabled = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-translation-on")
        _ = try textAnchor("Original meeting sentence", in: enabled)
        _ = try textAnchor("GREEN BUTTON", in: enabled)
        defaults.set(false, forKey: TranslationDefaults.enabledKey)
        settleAcceptanceHost(hosting)
        let disabled = try await acceptanceWords(hosting, appearance: appearance, name: "acceptance-translation-off")
        _ = try textAnchor("Original meeting sentence", in: disabled)
        XCTAssertFalse(disabled.contains { $0.text.contains("GREEN BUTTON") })
    }

    func testProductionPublisherCoalescesFramesAndClearsRestartedInterims() async throws {
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }
        let initialFinalRevision = session.transcriptRevision
        let initialDisplayRevision = session.transcriptDisplayRevision
        for text in ["First preview", "Second preview", "Latest preview"] {
            session.receiveTranscriptWordsForProof([acceptanceWord(text, speaker: 1, at: 0, final: false)], channel: "mic")
        }
        XCTAssertTrue(session.interimSegments.isEmpty, "Publication should be coalesced, not synchronous per socket frame")
        let previewArrived = try await waitForAcceptance { session.interimSegments.first?.text == "Latest preview" }
        XCTAssertTrue(previewArrived)
        XCTAssertEqual(session.transcriptRevision, initialFinalRevision)
        XCTAssertEqual(session.transcriptDisplayRevision, initialDisplayRevision,
                       "An unopened reader must not lay out every live frame")
        let (hosting, _) = try acceptanceHost(.aqua)
        defer { retireAcceptanceHost(hosting) }
        settleAcceptanceHost(hosting)
        XCTAssertEqual(session.transcriptRows.first?.visibleText, "Latest preview")
        let activeDisplayRevision = session.transcriptDisplayRevision
        XCTAssertGreaterThan(activeDisplayRevision, initialDisplayRevision)

        session.receiveTranscriptWordsForProof([acceptanceWord("Hello", speaker: 1, at: 0, final: true)], channel: "mic")
        session.receiveTranscriptWordsForProof([acceptanceWord(",", speaker: 1, at: 100, final: true)], channel: "mic")
        session.receiveTranscriptWordsForProof([acceptanceWord(" world!", speaker: 1, at: 200, final: true)], channel: "mic")
        let finalsArrived = try await waitForAcceptance { session.transcriptRevision == initialFinalRevision + 1 }
        XCTAssertTrue(finalsArrived)
        XCTAssertEqual(session.transcriptRows.first?.visibleText, "Hello, world!")
        XCTAssertTrue(session.interimSegments.isEmpty)
        XCTAssertEqual(session.transcriptDisplayRevision, activeDisplayRevision + 1)

        session.receiveTranscriptWordsForProof([acceptanceWord("Old pending words", speaker: 1, at: 300, final: false)], channel: "mic")
        let pendingArrived = try await waitForAcceptance { !session.interimSegments.isEmpty }
        XCTAssertTrue(pendingArrived)
        session.restartTranscriptStreamForProof(channel: "mic", atMs: 2_000)
        session.receiveTranscriptWordsForProof([acceptanceWord("After reconnect.", speaker: 1, at: 0, final: true)], channel: "mic")
        let restarted = try await waitForAcceptance { session.liveEntries.last?.startMs == 2_000 }
        XCTAssertTrue(restarted)
        XCTAssertTrue(session.interimSegments.isEmpty)
        XCTAssertEqual(session.transcriptRows.map(\.visibleText), ["Hello, world!", "After reconnect."])

        session.receiveTranscriptWordsForProof([acceptanceWord("Must not leak into the next session.", speaker: 1, at: 500, final: true)], channel: "mic")
        session.endTranscriptReplayForProof()
        session.beginTranscriptReplayForProof()
        let resetRevision = session.transcriptRevision
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(session.liveEntries.isEmpty)
        XCTAssertTrue(session.transcriptRows.isEmpty)
        XCTAssertEqual(session.transcriptRevision, resetRevision)
    }

    private func waitForAcceptance(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        return predicate()
    }

    private func settleAcceptanceHost(_ hosting: NSHostingView<AnyView>) {
        for _ in 0..<2 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func pressAcceptanceLabel(
        _ rect: CGRect, in hosting: NSHostingView<AnyView>, horizontalFraction: CGFloat = 0.5
    ) throws {
        let window = try XCTUnwrap(hosting.window as? NSPanel)
        let point = NSPoint(x: (rect.minX + rect.width * horizontalFraction) * hosting.bounds.width,
                            y: (hosting.isFlipped ? 1 - rect.midY : rect.midY) * hosting.bounds.height)
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        assertInteractionWindowIsOffscreen(window)
    }

    private func acceptanceWord(_ text: String, speaker: Int, at start: Int, final: Bool) -> SonioxWord {
        SonioxWord(text: text, startMs: start, endMs: start + 100, speaker: speaker,
                   confidence: 1, isFinal: final, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    private func acceptanceHost(_ name: NSAppearance.Name, windowed: Bool = false) throws -> (NSHostingView<AnyView>, NSAppearance) {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        UserDefaults.standard.set(
            name == .darkAqua ? RTIAppearanceMode.dark.rawValue : RTIAppearanceMode.light.rawValue,
            forKey: OverlayAppearanceDefaults.appearanceModeKey
        )
        let hosting = NSHostingView(rootView: AnyView(
            TranscriptTabView().padding(House.Spacing.lg).background(House.ColorToken.surface)
        ))
        hosting.appearance = appearance
        hosting.frame = NSRect(x: 0, y: 0, width: Self.narrowWidth, height: Self.height)
        if windowed {
            // Keep a real event-capable panel far outside every screen. It is
            // ordered behind other windows without activating the test app.
            let panel = OffscreenTranscriptPanel(
                contentRect: NSRect(x: -20_000, y: -20_000, width: Self.narrowWidth, height: Self.height),
                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.hasShadow = false
            panel.contentView = hosting
            panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            panel.orderBack(nil)
            interactionWindows[ObjectIdentifier(hosting)] = panel
            assertInteractionWindowIsOffscreen(panel)
        }
        return (hosting, appearance)
    }

    private func retireAcceptanceHost(_ hosting: NSHostingView<AnyView>) {
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if let panel = interactionWindows.removeValue(forKey: ObjectIdentifier(hosting)) {
            assertInteractionWindowIsOffscreen(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
    }

    private final class OffscreenTranscriptPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
    }

    private func assertInteractionWindowIsOffscreen(_ panel: NSPanel) {
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, getpid(),
                          "An interaction proof activated the test process")
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let ours = visible.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        XCTAssertFalse(displays.isEmpty)
        // WindowServer includes an ordered offscreen window in this list.
        // Check physical display intersection, including auxiliary windows.
        for window in ours {
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let rect = try? XCTUnwrap(bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            XCTAssertNotNil(rect)
            if let rect { XCTAssertFalse(displays.contains { $0.intersects(rect) }, "A test window reached a display") }
        }
    }

    private func acceptanceWords(
        _ hosting: NSHostingView<AnyView>, appearance: NSAppearance, name: String
    ) async throws -> [OCRService.RecognizedTextRegion] {
        _ = try captureSequenceFrame(hosting, appearance: appearance, name: name)
        let data = try Data(contentsOf: RenderProofHarness.outputDirectory.appendingPathComponent("\(name).png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let regions = try await OCRService.recognizeTextRegions(in: XCTUnwrap(bitmap.cgImage))
        let receipt = regions.map { "\($0.text) | \($0.boundingBox)" }.joined(separator: "\n")
        try receipt.write(to: RenderProofHarness.outputDirectory.appendingPathComponent("\(name)-ocr.txt"), atomically: true, encoding: .utf8)
        return regions
    }

    private func textAnchor(_ text: String, in regions: [OCRService.RecognizedTextRegion]) throws -> CGRect {
        let matches = regions.filter { $0.text.localizedCaseInsensitiveContains(text) }
        XCTAssertEqual(matches.count, 1, "Expected exactly one visible occurrence of \(text); OCR: \(regions.map(\.text))")
        return try XCTUnwrap(matches.first).boundingBox
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
