import AVFoundation
import Foundation

final class WAVWriter {
    private var file: AVAudioFile?
    private(set) var url: URL?

    static func defaultURL(for sessionId: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RTI/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(sessionId).wav")
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
            NSLog("[RTI] WAVWriter.append failed: \(error)")
        }
    }

    func close() {
        file = nil
    }
}
