import AVFoundation
import Foundation
import RTICore
import XCTest

/// Uses the real recorder and independently checks its durable PCM payload.
final class RecordingWriterAcceptanceTests: XCTestCase {
    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingWriterAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func buffer(_ samples: [Int16]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func samples(at url: URL) throws -> [Int16] {
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(bytes.count, 44)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .ascii), "RIFF")
        let payload = bytes.dropFirst(44)
        return stride(from: payload.startIndex, to: payload.endIndex, by: 2).map {
            Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8)
        }
    }

    func testPauseResumeKeepsMarkersAndUnequalLegLengths() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MeetingRecorder()
        try recorder.open(in: directory)
        recorder.appendMic(buffer([101, 102, 103]))
        recorder.appendSystem(buffer([201, 202]))
        recorder.appendMicSilence(matching: buffer([999, 999, 999, 999]))
        recorder.appendSystemSilence(matching: buffer([999]))
        recorder.appendMic(buffer([-101, -102]))
        recorder.appendSystem(buffer([-201, -202, -203]))
        let mic = try XCTUnwrap(recorder.micURL)
        let system = try XCTUnwrap(recorder.systemURL)
        // A crash after append returns must leave the same readable prefix.
        XCTAssertEqual(try samples(at: mic), [101, 102, 103, 0, 0, 0, 0, -101, -102])
        XCTAssertEqual(try samples(at: system), [201, 202, 0, -201, -202, -203])
        XCTAssertEqual(try AVAudioFile(forReading: mic).length, 9)
        XCTAssertEqual(try AVAudioFile(forReading: system).length, 6)
        recorder.close()
        XCTAssertEqual(try samples(at: mic), [101, 102, 103, 0, 0, 0, 0, -101, -102])
    }

    func testOpeningExistingRecordingRefusesToOverwriteItsOnlyAudio() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = MeetingRecorder()
        try first.open(in: directory)
        first.appendMic(buffer([1234, -2345, 3456]))
        first.close()
        let url = try XCTUnwrap(first.micURL)
        let original = try Data(contentsOf: url)
        let second = MeetingRecorder()
        XCTAssertThrowsError(try second.open(in: directory))
        second.close()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(second.micURL)
        XCTAssertNil(second.systemURL)
    }

    func testFailedSecondLegOpenRemovesOnlyNewFirstLeg() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let system = directory.appendingPathComponent("audio-system.wav")
        let existing = Data("existing invented system fixture".utf8)
        try existing.write(to: system)
        let recorder = MeetingRecorder()
        XCTAssertThrowsError(try recorder.open(in: directory))
        XCTAssertEqual(try Data(contentsOf: system), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio-mic.wav").path))
        XCTAssertNil(recorder.micURL)
        XCTAssertNil(recorder.systemURL)
    }

    func testUnsupportedFormatReportsFailureWithoutWritingFalse16kAudio() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MeetingRecorder()
        var failures: [String] = []
        recorder.onWriteFailure = { failures.append($0) }
        try recorder.open(in: directory)
        let wrongFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: wrongFormat, frameCapacity: 480)!
        input.frameLength = 480
        input.int16ChannelData![0].initialize(repeating: 1000, count: 480)
        recorder.appendMic(input)
        XCTAssertEqual(failures.count, 1)
        recorder.close()
        XCTAssertNil(recorder.micURL)
    }

    func testExistingSymlinkCannotRedirectOrTruncateRecordedAudio() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("invented-original.wav")
        let bytes = Data([0x12, 0x34, 0x56, 0x78])
        try bytes.write(to: original)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("audio-mic.wav"), withDestinationURL: original
        )
        let recorder = MeetingRecorder()
        XCTAssertThrowsError(try recorder.open(in: directory))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
