import Darwin
import Foundation
import RTICore
import XCTest

/// The research replay's performance half (recommendations 5.3): the same
/// invented Lumo text laid end to end for two hours of dense talk, replayed
/// accelerated through the shared coordinator with the Transcript tab
/// visible, and the guide, codebook, synthesis and Auto passes on their
/// staggered ticks against a stub that answers at once. Two variants: both
/// legs, and the room on the mic only. A checkpoint runs every 5 minutes.
///
/// It measures each flush, the longest main-thread gap (a 10 ms ping on the
/// main actor), pass preparation at minute 30 and minute 120, the
/// checkpoint's main-thread snapshot and memory growth from minute 10.
/// The numbers always print. The live heap limit (under 40 MB) always
/// asserts, because it does not depend on the machine's speed. The ratio
/// check (each pass prep at minute 120 within 1.5x of minute 30, medians)
/// compares sub-millisecond wall times, so it is gated with the other
/// timing limits; `LivePerfTests` asserts the index stays incremental
/// without a clock. The millisecond limits (flush p95 4 ms, main-actor gap
/// 50 ms, every pass prep 5 ms, checkpoint 5 ms) hold on the M5 they were
/// set on and assert only with `RTI_TIMING_TESTS=1`; on an M1 expect about
/// 1.8x (2026-11-12 perf audit, an estimate).
/// Auto's vault search budget on 3,000 invented files is
/// `VaultSearchBudgetTests` (RTITests).
@MainActor
final class ResearchReplayEnduranceTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?

    private var timingAsserted: Bool {
        ProcessInfo.processInfo.environment["RTI_TIMING_TESTS"] == "1"
    }

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-replay-endurance-\(UUID().uuidString)", isDirectory: true)
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

    func testTwoLegsForTwoHours() async throws {
        try await endure(micOnly: false)
    }

    func testRoomOnTheMicOnlyForTwoHours() async throws {
        try await endure(micOnly: true)
    }

    // MARK: - The stream

    /// One packet of final tokens and when it arrives (its last word plus 500 ms).
    private struct Packet {
        let leg: String
        let tokens: [SonioxWord]
        let arrivalMs: Int
    }

    /// The fixture's lines back to back with a 1.5 s pause, over and over,
    /// for `minutes`; each line cut into packets of up to eight tokens.
    private static func stream(minutes: Int, micOnly: Bool) throws -> [Packet] {
        let lines = try ResearchReplayFixture.batches()
        var packets: [Packet] = []
        var cursor = 0
        var index = 0
        while cursor < minutes * 60000 {
            let line = lines[index % lines.count]
            index += 1
            guard let first = line.tokens.first?.startMs else { continue }
            let shift = cursor - first
            let tokens = line.tokens.map { word in
                SonioxWord(text: word.text, providerStartMs: word.startMs + shift, providerEndMs: word.endMs + shift,
                           providerSpeaker: "0", providerConfidence: word.confidence, providerIsFinal: true,
                           providerTranslationStatus: "none", language: word.language, sourceLanguage: nil)
            }
            for start in stride(from: 0, to: tokens.count, by: 8) {
                let chunk = Array(tokens[start ..< min(start + 8, tokens.count)])
                packets.append(Packet(leg: micOnly ? "mic" : line.leg, tokens: chunk, arrivalMs: (chunk.last?.endMs ?? cursor) + 500))
            }
            cursor = (tokens.last?.endMs ?? cursor) + 1500
        }
        return packets
    }

    /// Valid empty replies, at once.
    private static func stub() -> LLMRequest {
        LLMRequest(collectStream: { messages, _, _, _ in
            let user = messages.last?.content ?? ""
            let text = if user.contains(#""minute""#) {
                "{}"
            } else if user.contains(#""known""#) {
                #"{"entries":[],"names":[]}"#
            } else if user.contains(#""sections""#) {
                #"{"suggestion":null,"evidence":[],"cells":[]}"#
            } else {
                #"{"cards":[]}"#
            }
            return LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
    }

    // MARK: - The run

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Bytes in use in every malloc zone: live objects only. Unlike
    /// `phys_footprint`, it falls when memory is freed, so a replay that
    /// runs after another one in the same test process measures its own
    /// growth (2026-11-13 review: the second variant measured 1 MB of
    /// footprint growth because it reused the first one's pages).
    private static func liveHeapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    @MainActor private final class Watchdog {
        var running = true
        var longestGap = 0.0
    }

    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    private func endure(micOnly: Bool, minutes: Int = 120) async throws {
        let variant = micOnly ? "mic only" : "two legs"
        let packets = try Self.stream(minutes: minutes, micOnly: micOnly)
        let document = try ResearchReplayFixture.guide()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof(startedAt: start)
        defer { session.endTranscriptReplayForProof() }
        let sessionID = try XCTUnwrap(session.currentSessionId)
        let owner = UUID()
        session.activateTranscriptPresentation(for: owner)
        defer { session.deactivateTranscriptPresentation(for: owner) }

        let guide = GuideSessionController.shared
        guide.useRequestForTest(Self.stub())
        defer {
            guide.endSession(sessionID)
            guide.useRequestForTest(LLMRequest(priority: .background))
        }
        guide.start(sessionID: sessionID, guide: document, guideURL: ResearchReplayFixture.guideURL, group: "G1",
                    roster: [], rosterURL: nil, startedAt: start)
        let directory = root.appendingPathComponent("codebook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let place = ResearchCodebookStore.Location(
            session: .init(id: sessionID, group: "G1", startedAt: Date().addingTimeInterval(-6 * 3600), folder: directory.lastPathComponent),
            directory: directory, project: nil
        )
        let codebook = ResearchCodebookController(makeRequest: { Self.stub() })
        try await codebook.attachForTest(ResearchCodebookStore.shared.update(
            place, .prepare(seeds: ResearchReplayFixture.seeds(), hypotheses: document.hypotheses ?? [])
        ), at: place)
        let suite = "ResearchReplayEndurance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = start
        let auto = AutoAssistController(request: Self.stub(), callTypes: .inMemory(.research), guide: guide,
                                        codebook: codebook, defaults: defaults, now: { clock })
        auto.reset(for: sessionID)
        defer { auto.stop() }

        // The main-actor watchdog: a ping every 10 ms; a late ping is a gap.
        let dog = Watchdog()
        let watchdog = Task { @MainActor in
            while dog.running {
                let asked = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 10_000_000)
                let late = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1_000_000 - 10
                dog.longestGap = max(dog.longestGap, late)
            }
        }

        // Memory growth counts from minute 10, after one-time set-up
        // (prompt texts, caches, the first checkpoint) has settled.
        var footprintBefore: UInt64?
        var heapBefore: Int?
        var footprints: [Double] = []
        var flushes: [Double] = []
        var prep: [String: [(minute: Double, ms: Double)]] = [:]
        var checkpoints: [(minute: Double, ms: Double)] = []
        func notePrep(_ name: String, minute: Double) {
            if let ms = PassSignpost.lastMilliseconds(name) {
                prep[name, default: []].append((minute, ms))
            }
        }
        var nextTick = 10
        var next = 0
        let began = DispatchTime.now().uptimeNanoseconds
        while next < packets.count {
            // Every scheduled event before the next packet arrives.
            while nextTick * 1000 <= packets[next].arrivalMs {
                clock = start.addingTimeInterval(TimeInterval(nextTick))
                let minute = Double(nextTick) / 60
                switch nextTick % 120 {
                case 40:
                    await guide.generateLive(sessionId: sessionID, at: clock)
                    notePrep("guide pass prep", minute: minute)
                case 80:
                    await codebook.generateLive(sessionID: sessionID)
                    notePrep("codebook pass prep", minute: minute)
                case 100:
                    await codebook.synthesize(sessionID: sessionID, nowMs: nextTick * 1000)
                default:
                    break
                }
                let sent = await auto.generate(sessionId: sessionID)
                if sent != nil {
                    notePrep("auto pass prep", minute: minute)
                }
                if nextTick % 300 == 0 {
                    await session.checkpoint(endedAt: clock)
                    if nextTick == 600 {
                        footprintBefore = Self.footprint()
                        heapBefore = Self.liveHeapBytes()
                    }
                    if nextTick % 1800 == 0 {
                        footprints.append(Double(Self.footprint()) / 1_048_576)
                    }
                    if let ms = PassSignpost.lastMilliseconds("checkpoint snapshot") {
                        checkpoints.append((minute, ms))
                    }
                }
                nextTick += 10
            }
            let packet = packets[next]
            next += 1
            session.receiveTranscriptWordsForProof(packet.tokens, channel: packet.leg)
            flushes.append(milliseconds { session.flushTranscriptForProof() })
            await Task.yield()
        }
        dog.running = false
        await watchdog.value
        let longestGap = dog.longestGap
        let wall = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        let growthMB = Double(Int64(Self.footprint()) - Int64(footprintBefore ?? 0)) / 1_048_576
        let heapGrowthMB = Double(Self.liveHeapBytes() - (heapBefore ?? 0)) / 1_048_576

        func samples(_ name: String, from: Double, to: Double) -> [Double] {
            (prep[name] ?? []).filter { $0.minute >= from && $0.minute < to }.map(\.ms)
        }
        let names = ["guide pass prep", "codebook pass prep", "auto pass prep"]
        let end = Double(minutes)
        let at30 = Dictionary(uniqueKeysWithValues: names.map { ($0, samples($0, from: 25, to: 35).max() ?? 0) })
        let at120 = Dictionary(uniqueKeysWithValues: names.map { ($0, samples($0, from: end - 10, to: end + 1).max() ?? 0) })
        let median30 = Dictionary(uniqueKeysWithValues: names.map { ($0, Self.percentile(samples($0, from: 20, to: 40), 0.5)) })
        let median120 = Dictionary(uniqueKeysWithValues: names.map { ($0, Self.percentile(samples($0, from: end - 20, to: end + 1), 0.5)) })
        let late = checkpoints.filter { $0.minute >= Double(minutes) - 10 }.map(\.ms).max() ?? 0
        let p95 = Self.percentile(flushes, 0.95)
        print("""
        Research replay endurance, \(variant), \(minutes) min accelerated in \(String(format: "%.1f", wall)) s: \
        \(packets.count) packets, \(session.liveEntries.count) entries; flush p95 \(String(format: "%.2f", p95)) ms, \
        max \(String(format: "%.2f", flushes.max() ?? 0)) ms; longest main-actor gap \(String(format: "%.1f", longestGap)) ms; \
        pass prep max at min 30 \(at30) and at min \(minutes) \(at120); checkpoint snapshot at min \(minutes) \
        \(String(format: "%.2f", late)) ms; live heap growth \(String(format: "%.1f", heapGrowthMB)) MB; \
        phys_footprint growth \(String(format: "%.1f", growthMB)) MB \
        (every 30 min: \(footprints.map { String(format: "%.0f", $0) }.joined(separator: ", ")) MB)
        """)

        XCTAssertGreaterThan(session.liveEntries.count, 1000)
        XCTAssertFalse(checkpoints.isEmpty)
        XCTAssertTrue(names.allSatisfy { !(prep[$0] ?? []).isEmpty }, "every pass ran: \(prep.keys)")
        // Live objects only, so the limit holds whichever variant runs first.
        XCTAssertGreaterThan(heapGrowthMB, 0.5, "the transcript itself is kept")
        XCTAssertLessThan(heapGrowthMB, 40, "live heap growth over \(minutes) minutes")
        guard timingAsserted else { return }
        // Guide and codebook prep read only the changed tail of the
        // utterance index (`GuideTranscript.liveSources`); Auto prep reads
        // a fixed window. A linear term shows as a ratio over 1.5 (guide
        // prep was 1.56 before 2026-11-13). Sub-millisecond medians are
        // noisy under load, so this sits behind the timing gate.
        for name in names {
            XCTAssertLessThanOrEqual(median120[name] ?? 0, max(median30[name] ?? 0, 0.2) * 1.5, "\(name): flat, not linear")
        }
        XCTAssertLessThan(p95, 4, "flush p95")
        XCTAssertLessThan(longestGap, 50, "longest main-actor gap")
        for name in names {
            XCTAssertLessThan(at120[name] ?? 0, 5, "\(name) at minute \(minutes)")
        }
        XCTAssertLessThan(late, 5, "checkpoint snapshot on main")
    }
}
