import AVFoundation
import RTICore
import XCTest

/// AUD-7: the mic tap must survive a device switch. Each engine run converts
/// with a converter owned by its own tap block (no shared state for `stop()`
/// or `restart()` to swap under the audio thread), and the tap is installed
/// with no format, so a format change between reading it and installing the
/// tap cannot raise AVAudioEngine's uncatchable exception. Synthetic buffers
/// and an offline engine only; no microphone.
final class MicTapConverterTests: XCTestCase {
    func testConverterFollowsAFormatChangeInsteadOfDroppingTheLeg() throws {
        let converter = try XCTUnwrap(MicTapConverter(inputFormat: Self.float(48000)))
        let first = try XCTUnwrap(converter.convert(Self.tone(rate: 48000, frames: 4800)))
        XCTAssertEqual(first.format, AudioCaptureManager.targetFormat)
        // The resampler holds back a few frames of its first buffer.
        XCTAssertGreaterThan(first.frameLength, 1200)
        XCTAssertTrue(hasSignal(first))

        // AirPods connect: the next buffers arrive at 44.1 kHz on the same tap.
        let switched = try XCTUnwrap(converter.convert(Self.tone(rate: 44100, frames: 4410)),
                                     "A new device format is converted, not dropped")
        XCTAssertGreaterThan(switched.frameLength, 1200)
        XCTAssertTrue(hasSignal(switched))
    }

    /// The old run's tap block can still be running when `restart()` stops
    /// the engine on main and builds the next one. It converts with its own
    /// converter, so every buffer it was handed still arrives.
    func testInFlightBuffersOfTheOldRunStillConvertWhileMainRestarts() throws {
        let manager = AudioCaptureManager()
        let delivered = Counter()
        manager.onPCMBuffer = { _ in delivered.increment() }
        let oldRun = try XCTUnwrap(MicTapConverter(inputFormat: Self.float(48000)))
        let newRun = try XCTUnwrap(MicTapConverter(inputFormat: Self.float(48000)))
        let buffer = Self.tone(rate: 48000, frames: 480)
        let iterations = 2000
        let done = expectation(description: "audio thread finished")
        DispatchQueue.global(qos: .userInteractive).async {
            let buffer = Self.tone(rate: 48000, frames: 480)
            for _ in 0 ..< iterations {
                manager.handleInputBuffer(buffer, converter: oldRun)
            }
            done.fulfill()
        }
        // Main: the restart's teardown, and the new run's first buffers.
        for _ in 0 ..< 200 {
            manager.stop()
            manager.handleInputBuffer(buffer, converter: newRun)
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(delivered.count, iterations + 200, "No buffer is lost or read through a released converter")
    }

    /// The production install path takes the bus format at install time, so
    /// a format read earlier can never mismatch it.
    func testTapInstalledWithoutAFormatReceivesBuffersInTheBusFormat() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let busFormat = Self.float(44100)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: busFormat)
        try engine.enableManualRenderingMode(.offline, format: Self.float(48000), maximumFrameCount: 4096)
        let converter = try XCTUnwrap(MicTapConverter(inputFormat: Self.float(16000)))
        let converted = Counter()
        let tapped = Counter()
        AudioCaptureManager.installInputTap(on: player) { buffer in
            tapped.increment()
            if converter.convert(buffer) != nil {
                converted.increment()
            }
        }
        defer { player.removeTap(onBus: 0) }
        try engine.start()
        player.scheduleBuffer(Self.tone(rate: 44100, frames: 44100))
        player.play()
        let render = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        for _ in 0 ..< 24 {
            _ = try engine.renderOffline(4096, to: render)
        }
        engine.stop()
        XCTAssertGreaterThan(tapped.count, 0)
        XCTAssertEqual(converted.count, tapped.count, "Every tapped buffer converts, whatever format the bus has")
    }

    // MARK: Helpers

    private static func float(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    }

    private static func tone(rate: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: float(rate), frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0 ..< Int(frames) {
            samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / rate)) * 0.5
        }
        return buffer
    }

    private func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.int16ChannelData else { return false }
        return (0 ..< Int(buffer.frameLength)).contains { data[0][$0] != 0 }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.withLock { value }
        }

        func increment() {
            lock.withLock { value += 1 }
        }
    }
}
