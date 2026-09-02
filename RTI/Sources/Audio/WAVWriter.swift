import AVFoundation
import Foundation
import RTICore

final class WAVWriter {
    private var file: AVAudioFile?
    private(set) var url: URL?

    static func defaultURL(for sessionId: String) -> URL {
        // Ephemeral mic-only buffer used by the live pipeline. The durable
        // recorder below separately keeps compact mic and system audio legs.
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        return recordingsDir.appendingPathComponent("\(sessionId).wav")
    }

    private static var recordingsDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RTI/sessions", isDirectory: true)
    }

    /// Delete orphan WAV files left by a prior crash.
    static func sweepStaleRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func open(at url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRateHz,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let file = file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            RTILog.log("WAVWriter.append failed: \(error)", category: .audio)
        }
    }

    func close() {
        file = nil
    }
}

/// Durable dual-leg source recording for the automatic post-meeting pass.
/// Keeping mic and system audio separate gives the upgrader clean channel
/// identity and avoids mixing two independently-clocked capture streams.
final class MeetingRecorder {
    var onWriteFailure: ((String) -> Void)?
    private var micFile: DurableWAVFile?
    private var systemFile: DurableWAVFile?
    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private var micFrames = 0
    private var systemFrames = 0

    func open(in directory: URL) throws {
        try? micFile?.close()
        try? systemFile?.close()
        micFile = nil
        systemFile = nil
        micURL = nil
        systemURL = nil
        micFrames = 0
        systemFrames = 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mic = directory.appendingPathComponent("audio-mic.wav")
        let system = directory.appendingPathComponent("audio-system.wav")
        do {
            micFile = try DurableWAVFile(url: mic)
            systemFile = try DurableWAVFile(url: system)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mic.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: system.path)
            micURL = mic
            systemURL = system
        } catch {
            RTILog.log("MeetingRecorder.open failed: \(error)", category: .audio)
            micFile = nil
            systemFile = nil
            micURL = nil
            systemURL = nil
            throw error
        }
    }

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: micFile) { micFrames += Int(buffer.frameLength) }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: systemFile) { systemFrames += Int(buffer.frameLength) }
    }

    func appendMicSilence(matching buffer: AVAudioPCMBuffer) {
        if writeSilence(frameCount: Int(buffer.frameLength), to: micFile) { micFrames += Int(buffer.frameLength) }
    }

    func appendSystemSilence(matching buffer: AVAudioPCMBuffer) {
        if writeSilence(frameCount: Int(buffer.frameLength), to: systemFile) { systemFrames += Int(buffer.frameLength) }
    }

    private func writeSilence(frameCount: Int, to file: DurableWAVFile?) -> Bool {
        guard let file, frameCount > 0 else { return false }
        do {
            try file.appendSilence(frameCount: frameCount)
            return true
        } catch {
            let message = "Durable meeting audio write failed: \(error.localizedDescription)"
            RTILog.log(message, category: .audio)
            onWriteFailure?(message)
            return false
        }
    }

    private func write(_ input: AVAudioPCMBuffer, to file: DurableWAVFile?) -> Bool {
        guard let file, let source = input.int16ChannelData else { return false }
        let count = Int(input.frameLength)
        guard count > 0 else { return false }
        do {
            try file.append(samples: source[0], count: count)
            return true
        } catch {
            let message = "Durable meeting audio write failed: \(error.localizedDescription)"
            RTILog.log(message, category: .audio)
            onWriteFailure?(message)
            return false
        }
    }

    func close() {
        try? micFile?.close()
        try? systemFile?.close()
        micFile = nil
        systemFile = nil
        if micFrames == 0, let micURL {
            try? FileManager.default.removeItem(at: micURL)
            self.micURL = nil
        }
        if systemFrames == 0, let systemURL {
            try? FileManager.default.removeItem(at: systemURL)
            self.systemURL = nil
        }
    }
}

/// PCM WAV writer whose header is valid after every appended audio block.
/// AVAudioFile finalizes its WAV header only when closed, which makes a
/// force-quit recording look empty. Here payload is appended first and the
/// RIFF/data sizes are then updated and synchronized. A kill between those
/// operations leaves the preceding complete block readable rather than
/// invalidating the whole meeting.
private final class DurableWAVFile {
    private static let headerBytes = 44
    private static let sampleRate = UInt32(AudioFormat.sampleRateHz)
    private static let bytesPerSample: UInt16 = 2

    private let handle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var isClosed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 0)
        try writeHeader(dataBytes: 0)
        try handle.synchronize()
    }

    func append(samples: UnsafePointer<Int16>, count: Int) throws {
        guard !isClosed, count > 0 else { return }
        let byteCount = count * Int(Self.bytesPerSample)
        guard UInt64(dataByteCount) + UInt64(byteCount) <= UInt64(UInt32.max - 36) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let data = Data(bytes: samples, count: byteCount)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataByteCount += UInt32(byteCount)
        try writeHeader(dataBytes: dataByteCount)
    }

    func appendSilence(frameCount: Int) throws {
        guard frameCount > 0 else { return }
        let silence = [Int16](repeating: 0, count: frameCount)
        try silence.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try append(samples: baseAddress, count: buffer.count)
        }
    }

    func close() throws {
        guard !isClosed else { return }
        try handle.synchronize()
        try handle.close()
        isClosed = true
    }

    private func writeHeader(dataBytes: UInt32) throws {
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(36 + dataBytes, to: &header)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(Self.sampleRate, to: &header)
        appendLittleEndian(Self.sampleRate * UInt32(Self.bytesPerSample), to: &header)
        appendLittleEndian(Self.bytesPerSample, to: &header)
        appendLittleEndian(UInt16(16), to: &header)
        header.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataBytes, to: &header)
        precondition(header.count == Self.headerBytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
