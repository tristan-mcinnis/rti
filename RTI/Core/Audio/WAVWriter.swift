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

/// Frames written to one leg and the clock time its audio began. A device
/// can stop delivering buffers (a Bluetooth output with nothing playing, a
/// tap rebuild, a mic restart), but the upgrade merges the legs with one
/// fixed offset, so a leg that falls behind the clock is filled with
/// silence first. Gaps under a second are ordinary delivery jitter.
private struct LegTimeline {
    static let maxLagFrames = AudioFormat.sampleRateHz
    var anchor: TimeInterval?
    var frames = 0

    /// Silence frames to write before `count` frames that arrive at `now`.
    mutating func gap(before count: Int, at now: TimeInterval) -> Int {
        let rate = Double(AudioFormat.sampleRateHz)
        guard let anchor else {
            anchor = now - Double(count) / rate
            return 0
        }
        let lag = Int((now - anchor) * rate) - frames - count
        return lag > Self.maxLagFrames ? lag : 0
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
    private var mic = LegTimeline()
    private var system = LegTimeline()
    private let now: () -> TimeInterval

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func open(in directory: URL) throws {
        close()
        micFile = nil
        systemFile = nil
        micURL = nil
        systemURL = nil
        mic = LegTimeline()
        system = LegTimeline()
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

    /// Anchor a leg when its capture starts rather than at its first
    /// buffer, so a device that starts silent is padded from the start too.
    /// Later calls (a backend fallback) keep the first anchor.
    public func markMicStarted() {
        if mic.anchor == nil { mic.anchor = now() }
    }

    public func markSystemStarted() {
        if system.anchor == nil { system.anchor = now() }
    }

    public func appendMic(_ buffer: AVAudioPCMBuffer) {
        append(buffer, silent: false, to: micFile, leg: &mic, name: "mic")
    }

    public func appendSystem(_ buffer: AVAudioPCMBuffer) {
        append(buffer, silent: false, to: systemFile, leg: &system, name: "system")
    }

    public func appendMicSilence(matching buffer: AVAudioPCMBuffer) {
        append(buffer, silent: true, to: micFile, leg: &mic, name: "mic")
    }

    public func appendSystemSilence(matching buffer: AVAudioPCMBuffer) {
        append(buffer, silent: true, to: systemFile, leg: &system, name: "system")
    }

    private func append(
        _ buffer: AVAudioPCMBuffer, silent: Bool, to file: DurableWAVFile?, leg: inout LegTimeline, name: String
    ) {
        let count = Int(buffer.frameLength)
        guard file != nil, count > 0, validFormat(buffer) else { return }
        let gap = leg.gap(before: count, at: now())
        if gap > 0, writeSilence(frameCount: gap, to: file) {
            leg.frames += gap
            CoreLog.log("filled \(gap * 1000 / AudioFormat.sampleRateHz) ms delivery gap in \(name) leg", category: "audio")
        }
        let written = silent ? writeSilence(frameCount: count, to: file) : write(buffer, to: file)
        if written { leg.frames += count }
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
        guard let file, let source = input.int16ChannelData else { return false }
        let count = Int(input.frameLength)
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

    /// Capture callbacks can still be in flight when this runs. The files
    /// stay referenced so those callbacks read a closed file, which ignores
    /// the append, rather than a reference being torn down under them.
    public func close() {
        for file in [micFile, systemFile] {
            do { try file?.close() } catch {
                let message = "Durable meeting audio close failed: \(error.localizedDescription)"
                CoreLog.log(message, category: "audio")
                onWriteFailure?(message)
            }
        }
        if mic.frames == 0, let micURL {
            try? FileManager.default.removeItem(at: micURL)
            self.micURL = nil
        }
        if system.frames == 0, let systemURL {
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

    private static let silenceChunkFrames = AudioFormat.sampleRateHz * 10

    private let handle: FileHandle
    /// Appends run on capture threads and close runs on main.
    private let lock = NSLock()
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
        try lock.withLock { try appendLocked(samples: samples, count: count) }
    }

    private func appendLocked(samples: UnsafePointer<Int16>, count: Int) throws {
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
        let silence = [Int16](repeating: 0, count: min(frameCount, Self.silenceChunkFrames))
        try silence.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var remaining = frameCount
            while remaining > 0 {
                let count = min(remaining, buffer.count)
                try append(samples: baseAddress, count: count)
                remaining -= count
            }
        }
    }

    public func close() throws {
        try lock.withLock { try closeLocked() }
    }

    private func closeLocked() throws {
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
