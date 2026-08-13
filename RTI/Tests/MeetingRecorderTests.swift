import AVFoundation
import XCTest

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
}
