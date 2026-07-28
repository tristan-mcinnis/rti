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
