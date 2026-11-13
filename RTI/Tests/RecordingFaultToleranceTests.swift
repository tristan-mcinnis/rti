import AVFoundation
import Foundation
import RTICore
import XCTest

/// The durable writer and the tap stall clock under injected faults: a failed
/// block, a disk that stays full, a lid closed mid-call, a Bluetooth tap that
/// goes quiet. Temp folders and invented PCM only.
final class RecordingFaultToleranceTests: XCTestCase {
    // MARK: F2: transient write failure

    func testOneFailedBlockIsOwedAsSilenceAndIsNotFatal() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = BlockFault(failMicBlocks: [2])
        var clock: TimeInterval = 100
        let recorder = MeetingRecorder(now: { clock }, writeFault: { fault.next($0) })
        var degraded: [String?] = []
        var fatal: [String] = []
        recorder.onWriteDegraded = { leg, message in
            XCTAssertEqual(leg, "mic")
            degraded.append(message)
        }
        recorder.onWriteFailure = { fatal.append($0) }
        try recorder.open(in: directory)
        recorder.markMicStarted()
        for value: Int16 in [1, 2, 3] {
            clock += 0.02
            recorder.appendMic(Self.buffer(value: value))
        }
        recorder.close()

        XCTAssertEqual(degraded.count, 2)
        XCTAssertNotNil(degraded.first ?? nil, "The first failure is reported with its error")
        XCTAssertNil(degraded.last ?? "not nil", "The next good block reports recovery")
        XCTAssertTrue(fatal.isEmpty)
        XCTAssertEqual(try Self.samples(XCTUnwrap(recorder.micURL)),
                       Array(repeating: 1, count: 320) + Array(repeating: 0, count: 320) + Array(repeating: 3, count: 320))
    }

    func testOnlyThirtySecondsOfContinuousFailureIsFatalAndOnlyOnce() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = BlockFault(failMicBlocks: Set(1 ... 1000))
        var clock: TimeInterval = 0
        let recorder = MeetingRecorder(now: { clock }, writeFault: { fault.next($0) })
        var degraded = 0
        var fatal: [String] = []
        recorder.onWriteDegraded = { _, _ in degraded += 1 }
        recorder.onWriteFailure = { fatal.append($0) }
        try recorder.open(in: directory)
        recorder.markMicStarted()
        for time in [0.0, 10, 20, 29.9] {
            clock = time
            recorder.appendMic(Self.buffer(value: 7))
        }
        XCTAssertTrue(fatal.isEmpty, "Under 30 s of failure the recording goes on")
        XCTAssertEqual(degraded, 1)
        for time in [30.0, 40, 50] {
            clock = time
            recorder.appendMic(Self.buffer(value: 7))
        }
        XCTAssertEqual(fatal.count, 1)
        XCTAssertTrue(fatal[0].contains("Free disk space"), "The user is told what to do")
        recorder.close()
    }

    // MARK: AUD-2: the gap clock counts sleep

    func testClockJumpOverSleepIsPaddedSoTheWAVMatchesWallTime() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 50
        let recorder = MeetingRecorder(now: { clock })
        try recorder.open(in: directory)
        recorder.markMicStarted()
        recorder.appendMic(Self.buffer(value: 1, frames: 16000))
        clock += 1
        // Lid closed for two minutes, then the next buffer.
        clock += 120
        recorder.appendMic(Self.buffer(value: 2, frames: 16000))
        recorder.close()
        // Started at 50, last buffer delivered at 171: 121 s of wall time.
        let frames = try AVAudioFile(forReading: XCTUnwrap(recorder.micURL)).length
        XCTAssertEqual(Double(frames) / 16000, 121, accuracy: 0.05, "WAV time equals wall time across the sleep")
    }

    func testDefaultRecorderClockIsTheSleepInclusiveMonotonicClock() {
        let monotonic = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        XCTAssertEqual(MeetingRecorder.sleepInclusiveUptime(), monotonic, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(MeetingRecorder.sleepInclusiveUptime(), ProcessInfo.processInfo.systemUptime - 0.5,
                                    "Uptime stops during sleep; the recorder's clock must not")
    }

    // MARK: AUD-3: the tap never abandons an idle leg

    func testTapStallPolicyRebuildsQuicklyThenSlowlyAndNeverGivesUp() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var policy = TapStallPolicy(startedAt: start)
        var rebuilds: [Int] = []
        for second in stride(from: 2, through: 200, by: 2) {
            let now = start.addingTimeInterval(TimeInterval(second))
            if policy.check(now: now, lastBufferAt: nil) != nil {
                rebuilds.append(second)
            }
        }
        XCTAssertEqual(rebuilds, [6, 12, 18, 78, 138, 198], "Three quick rebuilds, then one a minute, for as long as it is idle")
    }

    func testTapStallPolicyBufferRestartsTheQuickAttempts() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var policy = TapStallPolicy(startedAt: start)
        for second in [6, 12, 18] {
            XCTAssertNotNil(policy.check(now: start.addingTimeInterval(TimeInterval(second)), lastBufferAt: nil))
        }
        let spoke = start.addingTimeInterval(30)
        XCTAssertNil(policy.check(now: start.addingTimeInterval(32), lastBufferAt: spoke))
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(policy.check(now: start.addingTimeInterval(36), lastBufferAt: spoke), 1)
    }

    // MARK: Helpers

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFaultToleranceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func buffer(value: Int16, frames: Int = 320) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.int16ChannelData![0].initialize(repeating: value, count: frames)
        return buffer
    }

    private static func samples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
}

/// Fails the listed mic blocks (1-based), each once. Lock-guarded: the
/// recorder calls it on the appending thread.
private final class BlockFault: @unchecked Sendable {
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
