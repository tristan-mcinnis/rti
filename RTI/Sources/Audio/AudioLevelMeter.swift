import AVFoundation
import Foundation

/// A cheap snapshot of both capture legs for the Audio I/O monitor.
struct AudioLevels {
    var isRunning: Bool
    var systemActive: Bool
    var mic: Float
    var system: Float
    var micFlowing: Bool
    var systemFlowing: Bool
}

/// Thread-safe live-level + flow tracking for the two capture legs, so the
/// Audio I/O monitor can show — at a glance, mid-call — whether each side is
/// actually being captured. The connection-health dot says "the socket is
/// open"; these levels say "audio is actually moving." That distinction is
/// exactly what catches the AirPods / one-side-recorded failure.
///
/// Written from the audio render threads (the PCM callbacks) and read from the
/// main thread by the monitor, so every access is lock-guarded. Not @MainActor.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var micLevelValue: Float = 0
    private var systemLevelValue: Float = 0
    private var lastMicAt: TimeInterval = 0
    private var lastSystemAt: TimeInterval = 0

    /// A leg is "flowing" if it delivered a buffer within this window. The tap
    /// fires continuously while alive (even on silence), so no recent buffer =
    /// the leg is dead, independent of whether anyone is talking.
    private let flowWindow: TimeInterval = 1.5

    func recordMic(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.lock(); micLevelValue = level; lastMicAt = Self.now; lock.unlock()
    }

    func recordSystem(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.lock(); systemLevelValue = level; lastSystemAt = Self.now; lock.unlock()
    }

    func reset() {
        lock.lock()
        micLevelValue = 0; systemLevelValue = 0; lastMicAt = 0; lastSystemAt = 0
        lock.unlock()
    }

    struct Snapshot {
        let micLevel: Float
        let systemLevel: Float
        let micFlowing: Bool
        let systemFlowing: Bool
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let now = Self.now
        let snap = Snapshot(
            micLevel: micLevelValue,
            systemLevel: systemLevelValue,
            micFlowing: lastMicAt > 0 && now - lastMicAt < flowWindow,
            systemFlowing: lastSystemAt > 0 && now - lastSystemAt < flowWindow
        )
        lock.unlock()
        return snap
    }

    private static var now: TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    /// RMS of a 16-bit PCM buffer, normalised to ~0…1 with a speech-friendly
    /// boost so a normal talking voice fills a good chunk of the meter.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        let samples = channel[0]
        var sumSquares: Float = 0
        for i in 0 ..< n {
            let s = Float(samples[i]) / 32768.0
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(n)).squareRoot()
        return min(1, rms * 8)
    }
}
