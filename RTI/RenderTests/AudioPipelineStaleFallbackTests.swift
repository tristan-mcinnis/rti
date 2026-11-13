import AppKit
import AVFoundation
import RTICore
import XCTest

/// AUD-5: a ScreenCaptureKit fallback whose `start()` is still waiting (a
/// Screen Recording prompt) when the user stops and starts the next call must
/// never attach to that next call. Synthetic PCM, fake backends and the real
/// WAV writer in a temp folder; no device, provider or vault.
@MainActor
final class AudioPipelineStaleFallbackTests: XCTestCase {
    func testFallbackThatFinishesAfterTheNextCallStartedIsReleasedAndFeedsNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-stale-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The factory hands back the same backend object for both calls, so
        // only the capture generation can tell the two calls apart.
        let tap = InjectedSystemCapture()
        tap.fallsBackToScreenCapture = true
        let stale = GatedSystemCapture()
        var date = Date(timeIntervalSinceReferenceDate: 5000)
        var systemStarts = 0
        let pipeline = AudioPipeline(
            audio: InjectedMicrophoneCapture(), hasSTTKey: { true },
            makeSTTClient: { _, _, _ in InjectedSTTClient() },
            makeSystemCapture: { tap },
            makeFallbackSystemCapture: { stale },
            screenCapturePermitted: { true },
            workspaceNotifications: NotificationCenter(),
            systemAudioStartupDelayNs: 0,
            now: { date }, log: { _, _ in }
        )
        pipeline.onSystemAudioStarted = { _ in systemStarts += 1 }
        defer { pipeline.abort() }

        // Call 1: the tap never delivers, so the watchdog tries the fallback,
        // whose start waits on a prompt.
        try pipeline.prepare(recordingDirectory: root.appendingPathComponent("call-1"))
        try pipeline.start(micMuted: false)
        try await waitUntil { systemStarts == 1 }
        date = date.addingTimeInterval(9)
        let watchdog = Task { await pipeline.checkSystemAudioHealth() }
        try await waitUntil { stale.startCount == 1 }

        // The user stops, then starts call 2 while the prompt is still open.
        pipeline.finalize()
        XCTAssertTrue(pipeline.finish())
        try pipeline.prepare(recordingDirectory: root.appendingPathComponent("call-2"))
        try pipeline.start(micMuted: false)
        try await waitUntil { systemStarts == 2 }
        let stopsBefore = tap.stopCount
        try tap.onPCMBuffer?(pcm(value: 7, frames: 320))

        // The prompt closes: the old fallback finishes starting.
        stale.release()
        await watchdog.value
        XCTAssertEqual(stale.stopCount, 1, "The stale fallback is stopped, not installed")
        XCTAssertEqual(tap.stopCount, stopsBefore, "Call 2's own backend is left running")
        XCTAssertTrue(pipeline.systemAudioActive)
        try stale.onPCMBuffer?(pcm(value: 99, frames: 160))
        try tap.onPCMBuffer?(pcm(value: 8, frames: 320))

        pipeline.finalize()
        XCTAssertTrue(pipeline.finish())
        let system = try samples(pipeline.systemRecordingURL)
        XCTAssertEqual(system.count, 640, "Only call 2's backend wrote its leg")
        XCTAssertEqual(system, Array(repeating: 7, count: 320) + Array(repeating: 8, count: 320))
    }

    // MARK: Helpers

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func pcm(value: Int16, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioCaptureManager.targetFormat, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.int16ChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }

    private func samples(_ url: URL?) throws -> [Int16] {
        let file = try AVAudioFile(forReading: XCTUnwrap(url), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
}

/// A system backend whose `start()` waits until the test releases it, the way
/// ScreenCaptureKit waits on a Screen Recording prompt. Lock-guarded: the
/// pipeline reads it from its own tasks.
final class GatedSystemCapture: SystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var pcm: ((AVAudioPCMBuffer) -> Void)?
    private var error: ((String) -> Void)?
    private var starts = 0
    private var stops = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { pcm } }
        set { lock.withLock { pcm = newValue } }
    }

    var onError: ((String) -> Void)? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }

    func start() async throws {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                starts += 1
                if released {
                    return true
                }
                waiter = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }

    func stop() {
        lock.withLock { stops += 1 }
    }

    func captureHealth() -> SystemAudioCaptureHealth {
        SystemAudioCaptureHealth(duration: 0, audibleDuration: 0, lastBufferAt: nil,
                                 lastAudibleBufferAt: nil, lastRMSLevel: 0, peakRMSLevel: 0)
    }

    func recoverFromSilentAudio() async -> Bool {
        false
    }
}
