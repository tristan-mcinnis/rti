import AVFoundation
import RTICore
import XCTest

/// AUD-4: a leg that recorded nothing for a stretch must be written down in
/// session.json, transcript.md and the `-rti.md` sidecar. Synthetic PCM
/// through the production pipeline callbacks, the real WAV writer on a fake
/// clock, and the real archive in a temp vault; no device, provider or vault.
@MainActor
final class CaptureGapArchiveTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private let startedAt = Date(timeIntervalSince1970: 1_782_000_000)

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-capture-gaps-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ]).write(to: config.appendingPathComponent("config.json"))
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

    func testSystemGapAndSilentMicAreRecordedInEveryHandOffFile() async throws {
        let clock = FakeClock()
        let mic = ZeroMicrophone()
        let system = InjectedSystemCapture()
        var date = Date(timeIntervalSinceReferenceDate: 9000)
        var systemStarted = false
        let pipeline = AudioPipeline(
            audio: mic, hasSTTKey: { true }, makeSTTClient: { _, _, _ in InjectedSTTClient() },
            makeSystemCapture: { system }, workspaceNotifications: NotificationCenter(),
            systemAudioStartupDelayNs: 0, now: { date }, log: { _, _ in },
            recorder: MeetingRecorder(now: { clock.now })
        )
        pipeline.onSystemAudioStarted = { _ in systemStarted = true }
        defer { pipeline.abort() }
        try pipeline.prepare(recordingDirectory: root.appendingPathComponent("capture"))
        try pipeline.start(micMuted: false)
        for _ in 0 ..< 200 where !systemStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(systemStarted)

        // 1 s of the other side, then the tap goes quiet for 120 s, then 1 s more.
        for _ in 0 ..< 50 {
            try system.onPCMBuffer?(pcm(frames: 320))
            clock.advance(0.02)
        }
        clock.advance(120)
        date = date.addingTimeInterval(121)
        system.health = Self.audible(at: date)
        try system.onPCMBuffer?(pcm(frames: 320))
        try await waitUntil { pipeline.captureGaps.contains { $0.leg == .system } }

        // The mic then delivers only exact zeros for a minute.
        mic.zeroSeconds = 60
        pipeline.checkMicHealth()
        XCTAssertEqual(mic.restartCount, 1)
        date = date.addingTimeInterval(240)
        pipeline.finalize()
        XCTAssertTrue(pipeline.finish())

        let gaps = pipeline.captureGaps
        let systemGap = try XCTUnwrap(gaps.first { $0.leg == .system })
        XCTAssertEqual(systemGap.reason, .noAudio)
        XCTAssertEqual(Double(systemGap.startMs), 1000, accuracy: 100)
        XCTAssertEqual(try Double(XCTUnwrap(systemGap.endMs)), 121_000, accuracy: 100)
        let micGap = try XCTUnwrap(gaps.first { $0.leg == .mic })
        XCTAssertEqual(micGap.reason, .silentInput)
        XCTAssertEqual(micGap.startMs, 61000, "121 s into the call, silent for the last 60 s")
        XCTAssertEqual(micGap.endMs, 361_000, "Closed when the recording stopped")

        // Stop: the archive and the /meeting sidecar.
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(361),
            transcript: [LiveEntry(speakerId: "remote_1", text: "Invented words before the gap", startMs: 500, confidence: 1,
                                   translationStatus: "original", language: "en", sourceLanguage: nil)],
            chat: [], visualContext: [], notes: [], sessionId: "invented-gap-session",
            micRecordingURL: nil, systemRecordingURL: nil, systemAudioStartOffsetMs: 0,
            workstreamItem: nil, modeName: nil, captureGaps: gaps
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.captureGaps, gaps)
        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(transcript.contains("> **Recording gaps.**"), transcript)
        XCTAssertTrue(transcript.contains("The other side (system audio): 00:00:01 to 00:02:00 (1 min 59 s)"), transcript)
        XCTAssertTrue(transcript.contains("Your microphone: 00:01:01 to 00:06:01 (5 min). The microphone sent only silence."), transcript)
        XCTAssertTrue(transcript.contains("Invented words before the gap"))

        let sidecarURL = try XCTUnwrap(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: directory, callType: .client))
        let sidecar = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertTrue(sidecar.contains("## Recording gaps"), sidecar)
        XCTAssertTrue(sidecar.contains("The other side (system audio): 00:00:01 to 00:02:00"))

        // The upgraded transcript replaces transcript.md and keeps the block.
        _ = try TranscriptUpgradeArtifacts.installUpgradedTranscript(
            markdown: "# Transcript\n\n`0:00` **Remote speaker 1:** Invented upgraded words.", in: directory
        )
        let upgraded = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(upgraded.contains("The other side (system audio): 00:00:01 to 00:02:00"), upgraded)
    }

    /// A system capture that fails mid-call is recorded at once, so even a
    /// crash-safety checkpoint written before Stop shows it.
    func testSystemCaptureFailureIsInTheCheckpointAndClosedAtStop() async throws {
        let system = InjectedSystemCapture()
        var date = Date(timeIntervalSinceReferenceDate: 20000)
        var systemStarted = false
        let pipeline = AudioPipeline(
            audio: InjectedMicrophoneCapture(), hasSTTKey: { true }, makeSTTClient: { _, _, _ in InjectedSTTClient() },
            makeSystemCapture: { system }, workspaceNotifications: NotificationCenter(),
            systemAudioStartupDelayNs: 0, now: { date }, log: { _, _ in }
        )
        pipeline.onSystemAudioStarted = { _ in systemStarted = true }
        defer { pipeline.abort() }
        try pipeline.prepare(recordingDirectory: root.appendingPathComponent("capture"))
        try pipeline.start(micMuted: false)
        for _ in 0 ..< 200 where !systemStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        date = date.addingTimeInterval(300)
        system.health = Self.audible(at: date)
        system.onError?("Invented stream stop")
        try await waitUntil { pipeline.systemAudioOutageReported }
        XCTAssertEqual(pipeline.captureGaps, [CaptureGap(leg: .system, reason: .captureFailed, startMs: 300_000, endMs: nil)])

        let checkpoint = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(310), transcript: [],
            chat: [], visualContext: [], notes: [], sessionId: "invented-failed-leg",
            micRecordingURL: nil, systemRecordingURL: nil, systemAudioStartOffsetMs: 0,
            workstreamItem: nil, modeName: nil,
            unreadableChatCount: 1, captureGaps: pipeline.captureGaps
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: checkpoint).archive())
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.captureGaps?.first?.endMs, nil, "Open at the checkpoint")

        date = date.addingTimeInterval(60)
        pipeline.finalize()
        XCTAssertEqual(pipeline.captureGaps.first?.endMs, 360_000)
    }

    // MARK: Helpers

    /// Keeps the system watchdog quiet: only the event under test opens a gap.
    private static func audible(at date: Date) -> SystemAudioCaptureHealth {
        SystemAudioCaptureHealth(duration: 2, audibleDuration: 2, lastBufferAt: date,
                                 lastAudibleBufferAt: date, lastRMSLevel: 0.1, peakRMSLevel: 0.1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func pcm(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioCaptureManager.targetFormat, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.int16ChannelData![0].initialize(repeating: 300, count: Int(frames))
        return buffer
    }
}

/// The writer's clock. Lock-guarded: the recorder reads it on capture threads.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

/// A microphone whose buffers keep arriving but carry exact zeros, as when
/// another app's voice processing holds the built-in mic.
private final class ZeroMicrophone: MicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var zero: TimeInterval?
    private var restarts = 0
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRestarted: (() -> Void)?
    var micMuted = false
    var zeroSeconds: TimeInterval? {
        get { lock.withLock { zero } }
        set { lock.withLock { zero = newValue } }
    }

    var restartCount: Int {
        lock.withLock { restarts }
    }

    func start() throws {}
    func stop() {}
    func restart() throws {
        lock.withLock { restarts += 1 }
    }

    func secondsSinceLastBuffer() -> TimeInterval? {
        0
    }

    func secondsAllZero() -> TimeInterval? {
        zeroSeconds
    }
}
