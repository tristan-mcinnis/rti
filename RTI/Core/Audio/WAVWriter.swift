import AVFoundation
import Darwin
import Foundation

/// Temp-directory cleanup for the live pipeline's former mic-only WAV. That
/// copy duplicated `MeetingRecorder`'s mic leg (about 115 MB an hour) and was
/// never read, so it is no longer written; the sweep still removes files an
/// earlier build left behind.
public enum WAVWriter {
    private static var recordingsDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RTI/sessions", isDirectory: true)
    }

    /// Delete orphan WAV files left in temp by an earlier build or a crash.
    public static func sweepStaleRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Durable dual-leg source recording for the automatic post-meeting pass.
/// Keeping mic and system audio separate gives the upgrader clean channel
/// identity and avoids mixing two independently-clocked capture streams.
public final class MeetingRecorder {
    public var onWriteFailure: ((String) -> Void)?
    private var micFile: DurableWAVFile?
    private var systemFile: DurableWAVFile?
    public private(set) var micURL: URL?
    public private(set) var systemURL: URL?
    private var micFrames = 0
    private var systemFrames = 0

    public init() {}

    public func open(in directory: URL) throws {
        close()
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
            micURL = mic
            systemURL = system
        } catch {
            CoreLog.log("MeetingRecorder.open failed: \(error)", category: "audio")
            // Only remove files this open created. Existing recordings are
            // refused by the exclusive create and must survive the failure.
            if let micFile {
                try? micFile.close()
                try? FileManager.default.removeItem(at: mic)
            }
            if let systemFile {
                try? systemFile.close()
                try? FileManager.default.removeItem(at: system)
            }
            micFile = nil
            systemFile = nil
            micURL = nil
            systemURL = nil
            throw error
        }
    }

    public func appendMic(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: micFile) { micFrames += Int(buffer.frameLength) }
    }

    public func appendSystem(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: systemFile) { systemFrames += Int(buffer.frameLength) }
    }

    public func appendMicSilence(matching buffer: AVAudioPCMBuffer) {
        guard validFormat(buffer) else { return }
        if writeSilence(frameCount: Int(buffer.frameLength), to: micFile) { micFrames += Int(buffer.frameLength) }
    }

    public func appendSystemSilence(matching buffer: AVAudioPCMBuffer) {
        guard validFormat(buffer) else { return }
        if writeSilence(frameCount: Int(buffer.frameLength), to: systemFile) { systemFrames += Int(buffer.frameLength) }
    }

    private func writeSilence(frameCount: Int, to file: DurableWAVFile?) -> Bool {
        guard let file, frameCount > 0 else { return false }
        do {
            try file.appendSilence(frameCount: frameCount)
            return true
        } catch {
            let message = "Durable meeting audio write failed: \(error.localizedDescription)"
            CoreLog.log(message, category: "audio")
            onWriteFailure?(message)
            return false
        }
    }

    private func write(_ input: AVAudioPCMBuffer, to file: DurableWAVFile?) -> Bool {
        guard let file, validFormat(input), let source = input.int16ChannelData else { return false }
        let count = Int(input.frameLength)
        guard count > 0 else { return false }
        do {
            try file.append(samples: source[0], count: count)
            return true
        } catch {
            let message = "Durable meeting audio write failed: \(error.localizedDescription)"
            CoreLog.log(message, category: "audio")
            onWriteFailure?(message)
            return false
        }
    }

    public func close() {
        for file in [micFile, systemFile] {
            do { try file?.close() } catch {
                let message = "Durable meeting audio close failed: \(error.localizedDescription)"
                CoreLog.log(message, category: "audio")
                onWriteFailure?(message)
            }
        }
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

    private func validFormat(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.sampleRate == Double(AudioFormat.sampleRateHz),
              buffer.format.channelCount == 1 else {
            let message = "Durable meeting audio requires 16 kHz mono Int16 PCM."
            CoreLog.log(message, category: "audio")
            onWriteFailure?(message)
            return false
        }
        return true
    }
}

/// PCM WAV writer whose header is valid after every appended audio block.
/// AVAudioFile finalizes its WAV header only when closed, which makes a
/// force-quit recording look empty. Here payload is appended first and the
/// RIFF/data sizes are then updated. The file is synchronized on close, not
/// after each block: process termination after append returns retains a
/// readable file, but this does not promise survival of sudden power loss.
/// A kill before a header update leaves the preceding complete block
/// readable. Termination during a header write is not an atomic checkpoint.
private final class DurableWAVFile {
    private static let headerBytes = 44
    private static let sampleRate = UInt32(AudioFormat.sampleRateHz)
    private static let bytesPerSample: UInt16 = 2

    private let handle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var isClosed = false

    public init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try writeHeader(dataBytes: 0)
            try handle.synchronize()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func append(samples: UnsafePointer<Int16>, count: Int) throws {
        guard !isClosed, count > 0 else { return }
        let byteCount = count * Int(Self.bytesPerSample)
        guard UInt64(dataByteCount) + UInt64(byteCount) <= UInt64(UInt32.max - 36) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let data = Data(bytes: samples, count: byteCount)
        let committedBytes = dataByteCount
        do {
            try handle.seek(toOffset: UInt64(Self.headerBytes) + UInt64(committedBytes))
            try handle.write(contentsOf: data)
            let nextBytes = committedBytes + UInt32(byteCount)
            try writeHeader(dataBytes: nextBytes)
            dataByteCount = nextBytes
        } catch {
            // FileHandle can write a prefix before throwing (for example
            // ENOSPC/EFBIG). Do not let that prefix contaminate a later block.
            try? handle.truncate(atOffset: UInt64(Self.headerBytes) + UInt64(committedBytes))
            try? writeHeader(dataBytes: committedBytes)
            throw error
        }
    }

    public func appendSilence(frameCount: Int) throws {
        guard frameCount > 0 else { return }
        let silence = [Int16](repeating: 0, count: frameCount)
        try silence.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try append(samples: baseAddress, count: buffer.count)
        }
    }

    public func close() throws {
        guard !isClosed else { return }
        defer { isClosed = true }
        do { try handle.synchronize() } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
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
