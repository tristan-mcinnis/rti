import Foundation
import HouseDesign
import Observation
import os
import RTICore
import SwiftUI
import XCTest

/// The 2026-11-13 M1 performance fixes in the app layer: a two-hour call
/// replayed through the real coordinator (invented Mandarin-like text, no
/// capture, no provider, a private temporary vault). Timing assertions are
/// opt-in (`RTI_TIMING_TESTS=1`); the measured numbers always go to the log.
@MainActor
final class LivePerfTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private static let syllables = Array("我们觉得这个品牌很好用但是价格有点贵平时跑步会买")
    private var timingAsserted: Bool {
        ProcessInfo.processInfo.environment["RTI_TIMING_TESTS"] == "1"
    }

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-live-perf-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ])
        try data.write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)
    }

    override func tearDown() async throws {
        if let savedConfigHome {
            setenv("RTI_CONFIG_HOME", savedConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// Replay `minutes` of two-leg speech, 2 s per packet, into the shared
    /// coordinator. `fromMinute` continues an earlier replay.
    private func replay(minutes: Int, fromMinute: Int = 0) {
        for step in (fromMinute * 30) ..< ((fromMinute + minutes) * 30) {
            packet(step)
        }
    }

    private func packet(_ step: Int) {
        var rng = SystemRandomNumberGenerator()
        let session = SessionCoordinator.shared
        do {
            let start = step * 2000
            let system = step % 3 == 2
            var words: [SonioxWord] = []
            for index in 0 ..< 8 {
                let syllable = Self.syllables[Int.random(in: 0 ..< Self.syllables.count, using: &rng)]
                let ms = start + index * 230 - (system ? 2500 : 0)
                words.append(SonioxWord(text: String(syllable), startMs: max(0, ms), endMs: max(0, ms) + 200, speaker: 0,
                                        confidence: 1, isFinal: true, translationStatus: "none", language: "zh", sourceLanguage: nil))
            }
            let end = start + 8 * 230 - (system ? 2500 : 0)
            words.append(SonioxWord(text: step % 4 == 0 ? "？" : "。", startMs: max(0, end), endMs: max(0, end) + 50, speaker: 0,
                                    confidence: 1, isFinal: true, translationStatus: "none", language: "zh", sourceLanguage: nil))
            session.receiveTranscriptWordsForProof(words, channel: system ? "system" : "mic")
        }
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func describe(_ sources: [GuideTranscript.Source]) -> [String] {
        sources.map { "\($0.turn.id)|\($0.turn.speaker)|\($0.turn.startMs)|\($0.endMs)|\($0.attributable)|\($0.turn.text)" }
    }

    // MARK: - Fixes 2 and 9: pass prep reads the index; no held copy

    func testPassPrepStaysFlatAndMatchesAFullRegroup() {
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }

        let rebuildsBefore = session.transcriptPipeline.utteranceIndexRebuilds
        // Read every two minutes, as the passes do; each incremental read
        // (which skips the settled prefix) equals a full regroup.
        for minute in stride(from: 0, to: 30, by: 2) {
            replay(minutes: 2, fromMinute: minute)
            XCTAssertEqual(describe(GuideTranscript.liveSources()), describe(GuideTranscript.sources(from: session.liveEntries)),
                           "minute \(minute + 2)")
        }
        replay(minutes: 2, fromMinute: 30)
        let sources30 = milliseconds { _ = GuideTranscript.liveSources() }
        let window30 = milliseconds { _ = TranscriptContext.text(forSessionId: "", sinceMs: 30 * 60000) }

        replay(minutes: 88, fromMinute: 32)
        _ = GuideTranscript.liveSources()
        replay(minutes: 2, fromMinute: 120)
        let sources120 = milliseconds { _ = GuideTranscript.liveSources() }
        let window120 = milliseconds { _ = TranscriptContext.text(forSessionId: "", sinceMs: 120 * 60000) }
        let regroup120 = milliseconds { _ = GuideTranscript.sources(from: session.liveEntries) }
        print("Pass prep ms: guide/codebook sources min30 \(sources30), min122 \(sources120); "
            + "Auto window min30 \(window30), min122 \(window120); full regroup min122 \(regroup120)")

        XCTAssertEqual(describe(GuideTranscript.liveSources()), describe(GuideTranscript.sources(from: session.liveEntries)),
                       "the live index gives exactly the full regroup's sources")
        // One build at the first read, one after the 88-minute jump (more
        // entries than the pipeline's recent window); 2-minute steps are incremental.
        XCTAssertEqual(session.transcriptPipeline.utteranceIndexRebuilds - rebuildsBefore, 2)
        guard timingAsserted else { return }
        XCTAssertLessThan(sources120, 5)
        XCTAssertLessThan(window120, 5)
        XCTAssertLessThan(sources120, max(1, sources30) * 2, "flat, not linear")
    }

    func testTheCoordinatorHoldsNoSecondCopyOfTheTranscript() async throws {
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }
        replay(minutes: 5)
        let revision = session.transcriptRevision
        for _ in 0 ..< 100 where session.transcriptRevision == revision {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(session.transcriptRevision, revision, "a flush published the finals")
        XCTAssertEqual(session.liveEntries.count, session.transcriptPipeline.liveEntries.count)

        // After a flush, appending a final must not copy the whole array:
        // with spare capacity it stays in the same buffer.
        func buffer() -> (address: UInt, count: Int, capacity: Int) {
            session.transcriptPipeline.liveEntries.withUnsafeBufferPointer {
                (UInt(bitPattern: $0.baseAddress), $0.count, session.transcriptPipeline.liveEntries.capacity)
            }
        }
        let before = buffer()
        packet(5 * 30)
        let after = buffer()
        XCTAssertGreaterThan(after.count, before.count)
        if after.count <= before.capacity {
            XCTAssertEqual(before.address, after.address, "the append reused the buffer, so nothing else held it")
        }
    }

    // MARK: - Fix 3: checkpoint snapshot on main, write off main

    func testCheckpointTakesOnlyTheSnapshotOnMain() async throws {
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }
        replay(minutes: 120)
        // The first checkpoint also wakes the shared stores; time the second.
        await session.checkpoint(endedAt: Date())
        await session.checkpoint(endedAt: Date())
        let snapshotMs = try XCTUnwrap(PassSignpost.lastMilliseconds("checkpoint snapshot"))
        let directory = try XCTUnwrap(try SessionArchive.sessionDirectory(startedAt: XCTUnwrap(session.startedAt)))
        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(transcript.contains("我") || transcript.contains("们"), "the checkpoint wrote the transcript")
        let finalWrite = milliseconds { _ = session.archiveCurrentSession(endedAt: Date()) }
        print("Checkpoint at two hours: main-thread snapshot \(snapshotMs) ms; the old all-on-main write \(finalWrite) ms")
        guard timingAsserted else { return }
        XCTAssertLessThan(snapshotMs, 5)
    }

    func testAnOlderCheckpointNeverOverwritesANewerWrite() {
        let gate = ArchiveWriteGate()
        let older = gate.nextSequence()
        let newer = gate.nextSequence()
        var order: [Int] = []
        _ = gate.run(newer) { order.append(newer); return nil }
        _ = gate.run(older) { order.append(older); return nil }
        XCTAssertEqual(order, [newer], "the older job is skipped")
    }

    // MARK: - Fix 5: the rail does not redraw per flush

    func testFlushActivityDoesNotInvalidateTheRail() throws {
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }
        let suite = "LivePerfTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let auto = AutoAssistController(callTypes: .inMemory(.client), guide: GuideSessionController(),
                                        codebook: ResearchCodebookController(), defaults: defaults, now: { clock })
        defer { auto.stop() }
        XCTAssertTrue(auto.isActiveForCall)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        func track() {
            withObservationTracking {
                _ = LiveRailContent.live(callType: .client, autoOn: true, auto: auto, guide: GuideSessionController(),
                                         codebook: ResearchCodebookController(), showsPinyin: false)
            } onChange: {
                changes.withLock { $0 += 1 }
            }
        }
        track()
        // Ten minutes of finals at about one flush a second.
        for second in 0 ..< 600 {
            clock = clock.addingTimeInterval(1)
            auto.noteActivity(selfSpoke: second.isMultiple(of: 3))
        }
        XCTAssertEqual(changes.withLock { $0 }, 0, "flush activity must not redraw the rail")
        auto.pin(UUID())
        XCTAssertEqual(changes.withLock { $0 }, 1, "a real rail change still redraws it")
    }

    // MARK: - Fix 6: staggered periodic passes

    func testPeriodicPassesStartAtDifferentPointsOfTheInterval() {
        SessionCoordinator.shared.registerPeriodicTasks()
        let offsets = AutoAssistScheduler.shared.offsets(interval: 120)
        XCTAssertEqual(offsets["notes"], 0)
        XCTAssertEqual(offsets["autoAssist"] ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(offsets["guide"] ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(offsets["researchCodebook"] ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(offsets["researchCodebookSynthesis"] ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(Set(offsets.values).count, offsets.count, "no two passes prepare on the same tick")
    }

    // MARK: - Fix 10 and the Notes backlog cap

    func testMicMeterTicksSlowlyAndRedrawsOnlyOnAWholePointChange() {
        XCTAssertEqual(MicLevelBar.tick, 0.3)
        XCTAssertEqual(MicLevelBar.width(for: 0), 3)
        XCTAssertEqual(MicLevelBar.width(for: 1), 14)
        XCTAssertEqual(MicLevelBar.width(for: 0.51), MicLevelBar.width(for: 0.53), "a small level change draws the same width")
        // The drawn capsule is the equatable child: equal widths skip its body.
        XCTAssertEqual(MicLevelBar.Capsule(width: MicLevelBar.width(for: 0.51)),
                       MicLevelBar.Capsule(width: MicLevelBar.width(for: 0.53)))
        XCTAssertNotEqual(MicLevelBar.Capsule(width: MicLevelBar.width(for: 0.2)),
                          MicLevelBar.Capsule(width: MicLevelBar.width(for: 0.8)))
    }

    /// The bar at silence, half and full level, under the mic glyph as in
    /// the toolbar. PNG `perf-mic-level-bar-*`.
    func testMicLevelBarRendersAtThreeLevels() throws {
        let view = HStack(spacing: House.Spacing.lg) {
            ForEach([Float(0), 0.5, 1], id: \.self) { level in
                ZStack(alignment: .bottom) {
                    Image(systemName: "mic.fill")
                        .font(RTIDesign.Font.meta)
                        .foregroundStyle(Color.overlayInkSecondary)
                    MicLevelBar(level: { level })
                        .padding(.bottom, 3)
                }
                .frame(width: House.Control.keyCap + House.Spacing.xxs, height: House.Control.chip)
            }
        }
        .padding(House.Spacing.md)
        .background(House.ColorToken.surface)
        try RenderProofHarness.renderBothAppearances(name: "perf-mic-level-bar", size: CGSize(width: 200, height: 60), view: view)
    }

    func testANotesBacklogKeepsOnlyItsNewestPart() {
        let session = SessionCoordinator.shared
        let entries = (0 ..< 40).map { index in
            LiveEntry(speakerId: "remote", text: String(repeating: "说", count: 500), startMs: index * 60000, confidence: 1,
                      translationStatus: "none", language: "zh", sourceLanguage: nil)
        }
        session.seedForRenderProof(entries: entries, interim: nil, phase: .recording, startedAt: Date())
        defer { session.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil) }
        let window = TranscriptContext.text(forSessionId: "", sinceMs: nil)
        let start = NotesGenerationController.backlogStart(window: window, sinceMs: nil, sessionElapsedMs: 40 * 60000, interval: 120)
        XCTAssertNotNil(start)
        let kept = entries.filter { $0.startMs > (start ?? Int.max) }.map(\.text.count).reduce(0, +)
        XCTAssertLessThanOrEqual(kept, NotesGenerationController.backlogCharacters)
        XCTAssertGreaterThan(kept, NotesGenerationController.backlogCharacters - 500)
        XCTAssertNil(NotesGenerationController.backlogStart(window: window, sinceMs: 36 * 60000, sessionElapsedMs: 40 * 60000, interval: 120),
                     "a window inside two intervals is never cut")
    }
}
