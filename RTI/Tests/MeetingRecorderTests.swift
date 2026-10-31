import AVFoundation
import XCTest
import RTICore

final class MeetingRecorderTests: XCTestCase {
    func testWritesBothDurableWAVLegs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = MeetingRecorder()
        try recorder.open(in: directory)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
        buffer.frameLength = 320
        buffer.int16ChannelData![0].initialize(repeating: 1_000, count: 320)

        recorder.appendMic(buffer)
        recorder.appendSystem(buffer)
        recorder.close()

        let micURL = try XCTUnwrap(recorder.micURL)
        let systemURL = try XCTUnwrap(recorder.systemURL)
        XCTAssertEqual(micURL.lastPathComponent, "audio-mic.wav")
        XCTAssertEqual(systemURL.lastPathComponent, "audio-system.wav")
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 320)
        XCTAssertEqual(try AVAudioFile(forReading: systemURL).length, 320)
    }

    func testReopenRemovesEmptyLegsAndResetsOldURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = MeetingRecorder()
        try recorder.open(in: directory)
        recorder.close()

        XCTAssertNil(recorder.micURL)
        XCTAssertNil(recorder.systemURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio-mic.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio-system.wav").path))
    }

    func testWAVHeaderIsReadableBeforeRecorderCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = MeetingRecorder()
        try recorder.open(in: directory)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        buffer.int16ChannelData![0].initialize(repeating: 1_000, count: 32_000)
        recorder.appendMic(buffer)

        let micURL = try XCTUnwrap(recorder.micURL)
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 32_000)
        recorder.close()
    }

    func testDeliveryGapIsFilledSoTheLegKeepsClockTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 100
        let recorder = MeetingRecorder(now: { clock })
        try recorder.open(in: directory)
        let buffer = Self.buffer(frames: 1_600)

        recorder.appendSystem(buffer)
        clock += 0.1
        recorder.appendSystem(buffer)
        clock += 30
        recorder.appendSystem(buffer)
        recorder.close()

        let systemURL = try XCTUnwrap(recorder.systemURL)
        XCTAssertEqual(Double(try AVAudioFile(forReading: systemURL).length), 30.2 * 16_000, accuracy: 2)
    }

    func testDeliveryJitterUnderASecondAddsNoSilence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 100
        let recorder = MeetingRecorder(now: { clock })
        try recorder.open(in: directory)
        let buffer = Self.buffer(frames: 1_600)

        recorder.appendMic(buffer)
        clock += 0.9
        recorder.appendMic(buffer)
        recorder.close()

        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(recorder.micURL)).length, 3_200)
    }

    func testAppendAfterCloseIsIgnoredWithoutAFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MeetingRecorder()
        var failures: [String] = []
        recorder.onWriteFailure = { failures.append($0) }
        try recorder.open(in: directory)
        recorder.appendMic(Self.buffer(frames: 320))
        recorder.close()

        recorder.appendMic(Self.buffer(frames: 320))

        XCTAssertEqual(failures, [])
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(recorder.micURL)).length, 320)
    }

    func testLegStartedBeforeItsFirstBufferIsPaddedFromTheStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 100
        let recorder = MeetingRecorder(now: { clock })
        try recorder.open(in: directory)

        recorder.markSystemStarted()
        clock += 5
        recorder.appendSystem(Self.buffer(frames: 1_600))
        clock += 20
        recorder.markSystemStarted()
        recorder.appendSystem(Self.buffer(frames: 1_600))
        recorder.close()

        let systemURL = try XCTUnwrap(recorder.systemURL)
        XCTAssertEqual(Double(try AVAudioFile(forReading: systemURL).length), 25 * 16_000, accuracy: 2)
    }

    private static func buffer(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.int16ChannelData![0].initialize(repeating: 1_000, count: frames)
        return buffer
    }
}
