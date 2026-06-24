import AVFoundation
import Foundation

final class WAVWriter {
    private var file: AVAudioFile?
    private(set) var url: URL?

    static func defaultURL(for sessionId: String) -> URL {
        // Ephemeral by design: the WAV is streamed to a temp file during the
        // session and deleted on stop. Use the temp directory (not Documents)
        // so the OS reaps any orphan left behind by a crash — raw meeting audio
        // must never linger in a user-visible location for a "nothing kept" app.
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        return recordingsDir.appendingPathComponent("\(sessionId).wav")
    }

    private static var recordingsDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RTI/sessions", isDirectory: true)
    }

    /// Delete any orphan WAV files left in the temp recordings dir by a prior
    /// crash. Safe to call at launch — no session is active then, so anything
    /// here is stale raw audio that must not linger (the app keeps no audio).
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
            AVSampleRateKey: 16_000,
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
            RTILog.log("WAVWriter.append failed: \(error)", category: "audio")
        }
    }

    func close() {
        file = nil
    }
}

/// Durable meeting recorder. Unlike `WAVWriter` (ephemeral, mic-only, 16 kHz
/// WAV that is deleted on stop), this keeps the **full meeting** as two compact
/// AAC m4a files — one for the mic leg, one for the system-audio leg — in the
/// vault's COS-synced recordings dir.
///
/// Why two files instead of a stereo mix:
///   - Clean speaker separation for the async re-transcribe pass — the mic file
///     is "you / the room you're in", the system file is "the remote side".
///     For a multi-person room (one device, many voices) the mic file is what a
///     diarization-capable provider clusters into per-speaker turns.
///   - No cross-stream drift: the two capture legs run on independent clocks and
///     the system leg starts later; interleaving them into one file would desync
///     over a long meeting. Separate files sidestep that entirely.
///
/// Input buffers are 16 kHz mono Int16 (the same stream fed to the transcriber);
/// they are converted to the file's Float32 processing format on write. 16 kHz
/// is the rate every speech model uses internally, so this loses nothing for
/// transcription or diarization.
final class MeetingRecorder {
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private var micFrames = 0
    private var systemFrames = 0

    private static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
    }

    /// Open both output files for a session. Best-effort: a failure to open
    /// (e.g. no writable vault) leaves the recorder inert rather than throwing,
    /// so a recording problem can never block the live session.
    @discardableResult
    func open(sessionId: String) -> URL? {
        let dir = MeetingRecorder.recordingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("rti-\(sessionId)-mic.m4a")
        let sys = dir.appendingPathComponent("rti-\(sessionId)-system.m4a")
        do {
            micFile = try AVAudioFile(forWriting: mic, settings: MeetingRecorder.aacSettings)
            systemFile = try AVAudioFile(forWriting: sys, settings: MeetingRecorder.aacSettings)
            micURL = mic
            systemURL = sys
            return dir
        } catch {
            RTILog.log("MeetingRecorder.open failed: \(error)", category: "audio")
            micFile = nil
            systemFile = nil
            return nil
        }
    }

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: micFile) { micFrames += Int(buffer.frameLength) }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        if write(buffer, to: systemFile) { systemFrames += Int(buffer.frameLength) }
    }

    /// Convert the incoming 16 kHz mono Int16 buffer to the file's Float32
    /// processing format and append. Each file is only ever written from its own
    /// capture thread, so no locking is needed.
    private func write(_ inBuf: AVAudioPCMBuffer, to file: AVAudioFile?) -> Bool {
        guard let file, let src = inBuf.int16ChannelData else { return false }
        let n = Int(inBuf.frameLength)
        guard n > 0 else { return false }
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData else { return false }
        out.frameLength = AVAudioFrameCount(n)
        let s = src[0], d = dst[0]
        for i in 0..<n { d[i] = Float(s[i]) / 32768.0 }
        do {
            try file.write(from: out)
            return true
        } catch {
            RTILog.log("MeetingRecorder write failed: \(error)", category: "audio")
            return false
        }
    }

    /// Close both files. A leg that never received audio (e.g. an in-room
    /// meeting with no system/remote audio) leaves an empty m4a behind, so it is
    /// deleted — only files with real audio are kept.
    func close() {
        micFile = nil
        systemFile = nil
        if micFrames == 0, let micURL { try? FileManager.default.removeItem(at: micURL); self.micURL = nil }
        if systemFrames == 0, let systemURL { try? FileManager.default.removeItem(at: systemURL); self.systemURL = nil }
    }

    /// The COS-synced vault recordings dir, or an Application Support fallback.
    static func recordingsDirectory() -> URL {
        if let rec = VaultLogStore.recordingsDirectory() { return rec }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("RTI/recordings", isDirectory: true)
    }
}
