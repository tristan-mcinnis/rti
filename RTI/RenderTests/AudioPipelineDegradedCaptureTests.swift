import AppKit
import AVFoundation
import RTICore
import XCTest

/// Capture faults that must degrade the recording, never end it: a mic that
/// stops or cannot rebind (AUD-1), system sleep (AUD-2), an idle or dead
/// process tap (AUD-3) and a brief disk write failure (F2). Synthetic PCM
/// enters the production callbacks and the real WAV writer in a temp folder;
/// no device, provider, window or vault is used.
@MainActor
final class AudioPipelineDegradedCaptureTests: XCTestCase {
    // MARK: AUD-1

    func testFailedMicRebindKeepsSessionAndSystemLegAndRetriesWithBackoff() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend)
        defer { fixture.cleanUp() }
        try await fixture.startWithSystem()
        try fixture.audio.emit(pcm(value: 100))
        try backend.onPCMBuffer?(pcm(value: 200))

        // An hour in, the device switches and the rebind fails mid-switch.
        fixture.date = fixture.date.addingTimeInterval(3600)
        fixture.audio.restartError = AudioCaptureError.converterCreationFailed
        try? fixture.audio.restart()
        XCTAssertEqual(fixture.audio.restartCount, 1)

        fixture.pipeline.checkMicHealth()
        XCTAssertEqual(fixture.notices, [AudioPipeline.micLostNotice])
        XCTAssertEqual(fixture.audio.restartCount, 2, "The watchdog rebinds at once")
        for (step, expected) in [(3.0, 2), (3.0, 3), (5.0, 3), (6.0, 4), (19.0, 4), (1.0, 5)] {
            fixture.date = fixture.date.addingTimeInterval(step)
            fixture.pipeline.checkMicHealth()
            XCTAssertEqual(fixture.audio.restartCount, expected, "Backoff 5 s, 10 s, 20 s")
        }
        XCTAssertTrue(fixture.errors.isEmpty, "Mic loss must not stop the session")
        XCTAssertEqual(fixture.audio.stopCount, 0)
        XCTAssertTrue(fixture.pipeline.systemAudioActive, "The healthy system leg keeps recording")
        XCTAssertEqual(backend.stopCount, 0)
        try backend.onPCMBuffer?(pcm(value: 300))

        // The device comes back: the next rebind works and buffers flow.
        fixture.audio.restartError = nil
        fixture.date = fixture.date.addingTimeInterval(40)
        fixture.pipeline.checkMicHealth()
        XCTAssertEqual(fixture.audio.restartCount, 6)
        try fixture.audio.emit(pcm(value: 400))
        fixture.pipeline.checkMicHealth()
        XCTAssertEqual(fixture.notices, [AudioPipeline.micLostNotice, nil], "The notice clears when audio returns")
        XCTAssertNil(fixture.pipeline.micOutageStartedAt)

        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL),
                       Array(repeating: 100, count: 320) + Array(repeating: 400, count: 320))
        XCTAssertEqual(try samples(fixture.pipeline.systemRecordingURL),
                       Array(repeating: 200, count: 320) + Array(repeating: 300, count: 320))
    }

    func testStoppedTapIsRebuiltBeforeAnyError() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.start()
        try fixture.audio.emit(pcm(value: 1))
        fixture.date = fixture.date.addingTimeInterval(60)
        fixture.audio.lastBufferAge = 9
        fixture.pipeline.checkMicHealth()
        XCTAssertEqual(fixture.audio.restartCount, 1, "A tap that just stops is rebound, not reported")
        XCTAssertTrue(fixture.errors.isEmpty)
        XCTAssertEqual(fixture.notices, [AudioPipeline.micLostNotice])
    }

    func testMicOutageBackoffCapsAtOneMinute() {
        let delays = (0 ..< 8).map { AudioPipeline.micOutageRestartDelay(attempt: $0) }
        XCTAssertEqual(delays, [0, 5, 10, 20, 40, 60, 60, 60])
    }

    // MARK: AUD-2

    func testSleepPausesWatchdogsAndWakeGivesAGraceBeforeRebinding() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend)
        defer { fixture.cleanUp() }
        try await fixture.startWithSystem()
        try fixture.audio.emit(pcm(value: 5))
        try backend.onPCMBuffer?(pcm(value: 6))
        backend.recovers = true

        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil { fixture.pipeline.isAsleep }
        // The watchdogs' clock counts sleep: their first tick lands before
        // any device has rebound.
        fixture.date = fixture.date.addingTimeInterval(900)
        fixture.audio.lastBufferAge = 900
        backend.health = Self.noBuffers
        fixture.pipeline.checkMicHealth()
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(fixture.audio.restartCount, 0)
        XCTAssertEqual(backend.recoveryCount, 0)

        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { !fixture.pipeline.isAsleep }
        fixture.pipeline.checkMicHealth()
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(fixture.audio.restartCount, 0, "Devices get a grace period after wake")
        XCTAssertEqual(backend.recoveryCount, 0)
        XCTAssertTrue(fixture.notices.isEmpty)

        fixture.date = fixture.date.addingTimeInterval(9)
        fixture.pipeline.checkMicHealth()
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(fixture.audio.restartCount, 1, "Still silent after the grace: rebind explicitly")
        XCTAssertEqual(backend.recoveryCount, 1)
        XCTAssertTrue(fixture.errors.isEmpty, "Waking never stops the session")
    }

    // MARK: AUD-3

    func testIdleTapThatDeliveredEarlierIsKeptAndRetriedForTheWholeCall() async throws {
        let tap = InjectedSystemCapture()
        tap.fallsBackToScreenCapture = true
        var fallbacks: [InjectedSystemCapture] = []
        let fixture = try Fixture(system: tap, fallback: {
            let sck = InjectedSystemCapture()
            sck.startError = SystemAudioError.permissionDenied
            fallbacks.append(sck)
            return sck
        })
        defer { fixture.cleanUp() }
        var health: [TranscriptionHealth] = []
        fixture.pipeline.onSystemAudioHealth = { health.append($0) }
        try await fixture.startWithSystem()
        try tap.onPCMBuffer?(pcm(value: 10))

        // Bluetooth output, nothing playing: every rebuild resets the tap's
        // own counters, so it looks like a tap that never worked.
        tap.health = Self.noBuffers
        tap.recovers = true
        for _ in 0 ..< 60 {
            fixture.date = fixture.date.addingTimeInterval(3)
            await fixture.pipeline.checkSystemAudioHealth()
        }
        XCTAssertTrue(fallbacks.isEmpty, "A tap that delivered this session is idle, not dead")
        XCTAssertEqual(tap.stopCount, 0)
        XCTAssertTrue(fixture.pipeline.systemAudioActive)
        XCTAssertGreaterThanOrEqual(tap.recoveryCount, 4, "Two quick rebuilds, then one a minute")

        // The other party speaks again.
        try tap.onPCMBuffer?(pcm(value: 20))
        tap.health = .init(duration: 1, audibleDuration: 1, lastBufferAt: fixture.date,
                           lastAudibleBufferAt: fixture.date, lastRMSLevel: 0.1, peakRMSLevel: 0.1)
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertNotEqual(health.last, .failed, "The outage notice is not latched for the rest of the call")
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())
        let system = try samples(fixture.pipeline.systemRecordingURL)
        XCTAssertEqual(system.prefix(320), ArraySlice(repeating: 10, count: 320))
        XCTAssertEqual(system.suffix(320), ArraySlice(repeating: 20, count: 320))
    }

    func testDeadTapFallsBackOnlyWithPermissionAndKeepsTheTapIfFallbackFails() async throws {
        // No Screen Recording permission: no fallback, no TCC prompt, tap kept.
        let deniedTap = InjectedSystemCapture()
        deniedTap.fallsBackToScreenCapture = true
        var deniedCalls = 0
        let denied = try Fixture(system: deniedTap, fallback: {
            deniedCalls += 1
            return InjectedSystemCapture()
        }, screenCapturePermitted: false)
        defer { denied.cleanUp() }
        try await denied.startWithSystem()
        denied.date = denied.date.addingTimeInterval(9)
        await denied.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(deniedCalls, 0)
        XCTAssertEqual(deniedTap.stopCount, 0)
        XCTAssertTrue(denied.pipeline.systemAudioActive)

        // Permission, but the fallback cannot start: the tap stays.
        let keptTap = InjectedSystemCapture()
        keptTap.fallsBackToScreenCapture = true
        let failing = InjectedSystemCapture()
        failing.startError = SystemAudioError.permissionDenied
        let kept = try Fixture(system: keptTap, fallback: { failing })
        defer { kept.cleanUp() }
        try await kept.startWithSystem()
        kept.date = kept.date.addingTimeInterval(9)
        await kept.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(failing.startCount, 1)
        XCTAssertEqual(keptTap.stopCount, 0, "The tap is released only after the fallback runs")
        XCTAssertTrue(kept.pipeline.systemAudioActive)
        try keptTap.onPCMBuffer?(pcm(value: 30))

        // Permission and a working fallback: swap, then the fallback records.
        let deadTap = InjectedSystemCapture()
        deadTap.fallsBackToScreenCapture = true
        let sck = InjectedSystemCapture()
        let swapped = try Fixture(system: deadTap, fallback: { sck })
        defer { swapped.cleanUp() }
        try await swapped.startWithSystem()
        swapped.date = swapped.date.addingTimeInterval(9)
        await swapped.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(deadTap.stopCount, 1)
        XCTAssertEqual(sck.startCount, 1)
        try sck.onPCMBuffer?(pcm(value: 40))
        swapped.pipeline.finalize()
        XCTAssertTrue(swapped.pipeline.finish())
        XCTAssertEqual(try samples(swapped.pipeline.systemRecordingURL).suffix(320), ArraySlice(repeating: 40, count: 320))
        kept.pipeline.finalize()
        XCTAssertTrue(kept.pipeline.finish())
        XCTAssertEqual(try samples(kept.pipeline.systemRecordingURL).suffix(320), ArraySlice(repeating: 30, count: 320))
    }

    // MARK: F2

    func testOneFailedWriteKeepsRecordingAndRecoversWithoutAFailure() async throws {
        let fault = WriteFault(failMicBlocks: [2])
        let fixture = try Fixture(recorder: MeetingRecorder(writeFault: { fault.next($0) }))
        defer { fixture.cleanUp() }
        var recordingNotices: [String?] = []
        fixture.pipeline.onRecordingNotice = { recordingNotices.append($0) }
        try fixture.start()
        try fixture.audio.emit(pcm(value: 1))
        try fixture.audio.emit(pcm(value: 2))
        try fixture.audio.emit(pcm(value: 3))
        try await waitUntil { recordingNotices.count == 2 }
        XCTAssertEqual(recordingNotices, [AudioPipeline.recordingWriteNotice, nil])
        XCTAssertTrue(fixture.errors.isEmpty, "One failed block must not stop the session")
        XCTAssertEqual(fixture.audio.stopCount, 0)
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish(), "A recovered write is not a recording failure")
        XCTAssertNil(fixture.pipeline.recordingFailureMessage, "Automatic processing stays queued")
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL),
                       Array(repeating: 1, count: 320) + Array(repeating: 0, count: 320) + Array(repeating: 3, count: 320),
                       "The failed block is kept as silence, so the timeline holds")
    }

    // MARK: Helpers

    private static let noBuffers = SystemAudioCaptureHealth(duration: 0, audibleDuration: 0, lastBufferAt: nil,
                                                            lastAudibleBufferAt: nil, lastRMSLevel: 0, peakRMSLevel: 0)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func pcm(value: Int16) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioCaptureManager.targetFormat, frameCapacity: 320))
        buffer.frameLength = 320
        buffer.int16ChannelData![0].initialize(repeating: value, count: 320)
        return buffer
    }

    private func samples(_ url: URL?) throws -> [Int16] {
        let file = try AVAudioFile(forReading: XCTUnwrap(url), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let audio = InjectedMicrophoneCapture()
        let workspace = NotificationCenter()
        var date = Date(timeIntervalSinceReferenceDate: 1000)
        var errors: [String] = []
        var notices: [String?] = []
        var pipeline: AudioPipeline!
        private var systemStarted = false

        init(
            system: InjectedSystemCapture? = nil,
            fallback: @escaping () -> SystemAudioCapturing = { InjectedSystemCapture() },
            screenCapturePermitted: Bool = true,
            recorder: PipelineRecording = MeetingRecorder()
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rti-degraded-capture-\(UUID().uuidString)")
            pipeline = AudioPipeline(
                audio: audio, hasSTTKey: { true }, makeSTTClient: { _, _, _ in InjectedSTTClient() },
                makeSystemCapture: system.map { backend in { backend } },
                makeFallbackSystemCapture: fallback,
                screenCapturePermitted: { screenCapturePermitted },
                workspaceNotifications: workspace,
                systemAudioEnabled: system != nil, systemAudioStartupDelayNs: 0,
                now: { [unowned self] in date }, log: { _, _ in }, recorder: recorder
            )
            pipeline.onError = { [unowned self] message, _ in errors.append(message) }
            pipeline.onMicNotice = { [unowned self] in notices.append($0) }
            pipeline.onSystemAudioStarted = { [unowned self] _ in systemStarted = true }
        }

        func start() throws {
            try pipeline.prepare(recordingDirectory: directory)
            try pipeline.start(micMuted: false)
        }

        func startWithSystem() async throws {
            try start()
            for _ in 0 ..< 200 where !systemStarted {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(systemStarted)
        }

        func cleanUp() {
            pipeline.abort()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Fails the listed mic blocks (1-based) once each. Lock-guarded: the
/// recorder calls it on the capture thread.
private final class WriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<Int>
    private var micBlocks = 0

    init(failMicBlocks: Set<Int>) {
        failing = failMicBlocks
    }

    func next(_ leg: String) -> Error? {
        lock.withLock {
            guard leg == "mic" else { return nil }
            micBlocks += 1
            return failing.remove(micBlocks) == nil ? nil : POSIXError(.ENOSPC)
        }
    }
}
