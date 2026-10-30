import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RTICore
import XCTest

/// Opt-in replay through AudioPipeline's real PCM and transcript
/// callbacks. Process metrics include XCTest. Capture devices and STT transport
/// are injected; this does not measure hardware capture or recognition quality.
/// Default cadence is real time; acceleration verifies audio-time workload only.
@MainActor
final class RealTimePipelineEnduranceTests: XCTestCase {
    func testTwoLegsAtRealTimeCadence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["RTI_PIPELINE_ENDURANCE_SECONDS"], let seconds = Double(raw) else {
            throw XCTSkip("Set RTI_PIPELINE_ENDURANCE_SECONDS to opt into real-time replay")
        }
        guard seconds >= 1, seconds <= 7_200 else {
            XCTFail("RTI_PIPELINE_ENDURANCE_SECONDS must be between 1 and 7200")
            return
        }
        let accelerated = environment["RTI_PIPELINE_ENDURANCE_ACCELERATED"] == "1"
        let cadence = accelerated ? "accelerated" : "realtime"
        let directory = URL(fileURLWithPath: environment["RTI_PIPELINE_ENDURANCE_ARTIFACT_DIR"]
            ?? "/tmp/rti-pipeline-endurance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let micSource = try Source(url: URL(fileURLWithPath: environment["RTI_PIPELINE_ENDURANCE_MIC_WAV"]
            ?? "/tmp/rti-recording-acceptance-20261030/fixtures/mic.wav"))
        let systemSource = try Source(url: URL(fileURLWithPath: environment["RTI_PIPELINE_ENDURANCE_SYSTEM_WAV"]
            ?? "/tmp/rti-recording-acceptance-20261030/fixtures/system.wav"))
        let microphone = InjectedMicrophoneCapture()
        let system = InjectedSystemCapture()
        var clients: [InjectedSTTClient] = []
        let pipeline = AudioPipeline(audio: microphone, hasSTTKey: { true }, makeSTTClient: { _, _ in
            let client = InjectedSTTClient()
            clients.append(client)
            return client
        }, makeSystemCapture: { system }, systemAudioStartupDelayNs: 0, log: { _, _ in })
        defer { pipeline.abort() }
        let transcript = TranscriptPipeline()
        var fatalErrors: [String] = []
        var providerErrors: [String] = []
        var callbackWordCount = 0
        var systemOffsetMs = 0
        var transcriptPublishTiming = Histogram()
        var callbackTiming = Histogram()
        var schedulingLag = Histogram()
        pipeline.onError = { message, _ in fatalErrors.append(message) }
        pipeline.onTranscriptionError = { message, _, channel in providerErrors.append("\(channel): \(message)") }
        pipeline.onWords = { words in
            let begin = ProcessInfo.processInfo.systemUptime
            callbackWordCount += words.count
            _ = transcript.process(words: words, channel: "mic")
            _ = transcript.liveEntries
            transcriptPublishTiming.record((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
        }
        pipeline.onSystemWords = { words in
            let begin = ProcessInfo.processInfo.systemUptime
            callbackWordCount += words.count
            _ = transcript.process(words: words, channel: "system")
            _ = transcript.liveEntries
            transcriptPublishTiming.record((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
        }
        pipeline.onStreamRestarted = { channel, offset in transcript.restartStream(channel: channel, atMs: offset) }
        let ready = expectation(description: "Injected system capture ready")
        pipeline.onSystemAudioStarted = {
            systemOffsetMs = $0
            transcript.setSystemStartOffset(ms: $0)
            ready.fulfill()
        }
        let recordingDirectory = directory.appendingPathComponent("retained-audio", isDirectory: true)
        try pipeline.prepare(recordingDirectory: recordingDirectory)
        try pipeline.start()
        await fulfillment(of: [ready], timeout: 5)
        guard clients.count == 2 else { XCTFail("Both injected transcription clients must exist"); return }
        clients[0].onStatus?(.live)
        clients[1].onStatus?(.live)

        let frameCount = 320 // 20 ms at 16 kHz, each leg gets one callback.
        let totalBlocks = Int((seconds * 50).rounded(.down))
        let began = ProcessInfo.processInfo.systemUptime
        let initialRSS = Self.residentBytes()
        var peakRSS = initialRSS
        let initialCPU = Self.cpuSeconds()
        var expectedMic = SHA256()
        var expectedSystem = SHA256()
        var pausedBlocks = 0
        var lateBlocks = 0
        var snapshots: [[String: Any]] = []
        var nextProgress = min(30.0, seconds)
        let silence = Data(count: frameCount * 2)
        let pauseStart = min(30.0, seconds / 3)
        let pauseLength = min(3.0, seconds / 6)
        async let pings = Self.schedulerPings(startedAt: began, seconds: accelerated ? 0 : seconds)
        try writeJSON([
            "state": "running", "seconds_requested": seconds, "started_at": ISO8601DateFormatter().string(from: Date()),
            "cadence": cadence, "playback_seconds_requested": Double(totalBlocks) / 50,
            "scheduling_metrics_available": !accelerated,
            "scope": "Real AudioPipeline, MeetingRecorder, WAVWriter and TranscriptPipeline; injected capture/STT and no-op pipeline logs; XCTest process metrics",
            "mic_source": micSource.url.path, "mic_source_sha256": micSource.sha256,
            "system_source": systemSource.url.path, "system_source_sha256": systemSource.sha256,
            "system_start_offset_ms": systemOffsetMs, "retained_audio_max_bytes": totalBlocks * frameCount * 4 + 1_024,
            "transcript_mode": "Injected English/Mandarin final tokens, not speech recognition",
            "pause_first_seconds": pauseStart, "pause_duration_seconds": pauseLength, "pause_repeat_seconds": 600
        ], to: directory.appendingPathComponent("manifest.json"))

        for block in 0..<totalBlocks {
            try Task.checkCancellation()
            let target = began + Double(block) / 50
            let wait = target - ProcessInfo.processInfo.systemUptime
            if !accelerated {
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let lag = max(0, ProcessInfo.processInfo.systemUptime - target)
                schedulingLag.record(lag * 1_000)
                if lag >= 0.02 { lateBlocks += 1 }
            }
            let elapsed = Double(block) / 50
            let pausePosition = (elapsed - pauseStart).truncatingRemainder(dividingBy: 600)
            pipeline.suspended = elapsed >= pauseStart && pausePosition >= 0 && pausePosition < pauseLength
            if pipeline.suspended { pausedBlocks += 1 }
            let micBuffer = try micSource.buffer(startFrame: block * frameCount, frameCount: frameCount)
            let systemBuffer = try systemSource.buffer(startFrame: block * frameCount, frameCount: frameCount)
            expectedMic.update(data: pipeline.suspended ? silence : Self.bytes(micBuffer))
            expectedSystem.update(data: pipeline.suspended ? silence : Self.bytes(systemBuffer))
            let before = ProcessInfo.processInfo.systemUptime
            microphone.emit(micBuffer)
            system.onPCMBuffer?(systemBuffer)
            callbackTiming.record((ProcessInfo.processInfo.systemUptime - before) * 1_000)
            let now = Date()
            system.health = .init(duration: elapsed + 0.02, audibleDuration: elapsed + 0.02,
                                  lastBufferAt: now, lastAudibleBufferAt: now, lastRMSLevel: 0.1, peakRMSLevel: 0.1)
            if block % 50 == 0, !pipeline.suspended {
                // Exercise production callback aggregation/publication once per
                // second. Leg-specific text avoids intentional echo filtering.
                let offset = block * 20
                clients[0].onWords?([Self.word("Synthetic English microphone segment \(block / 50). ", ms: offset, language: "en")])
                clients[1].onWords?([Self.word("合成普通话系统声音片段\(block / 50)。", ms: offset, language: "zh")])
            }
            let wallElapsed = ProcessInfo.processInfo.systemUptime - began
            if wallElapsed >= nextProgress {
                let rss = Self.residentBytes()
                peakRSS = max(peakRSS, rss)
                var sample: [String: Any] = ["elapsed_seconds": wallElapsed, "rss_bytes": rss,
                                  "cadence": cadence, "playback_seconds": Double(block + 1) / 50,
                                  "cpu_seconds": Self.cpuSeconds() - initialCPU,
                                  "blocks_per_leg": block + 1, "late_blocks": lateBlocks,
                                  "transcript_entries": transcript.liveEntries.count,
                                  "callback_ms": callbackTiming.json, "scheduler_lag_ms": schedulingLag.json]
                if accelerated { sample["scheduler_lag_ms"] = NSNull(); sample["late_blocks"] = NSNull() }
                snapshots.append(sample)
                try writeJSON(["state": "running", "samples": snapshots], to: directory.appendingPathComponent("progress.json"))
                nextProgress += 30
            }
            // Accelerated replay still lets the production lazy-client bridge
            // and lifecycle tasks run; it does not wait for audio wall time.
            if accelerated, block % 50 == 0 { await Task.yield() }
        }
        let finalWait = began + seconds - ProcessInfo.processInfo.systemUptime
        if !accelerated, finalWait > 0 { try await Task.sleep(for: .seconds(finalWait)) }
        let wallSeconds = ProcessInfo.processInfo.systemUptime - began
        pipeline.suspended = false
        let captureCPU = Self.cpuSeconds() - initialCPU
        let stopBegan = ProcessInfo.processInfo.systemUptime
        pipeline.finalize()
        let recordingClosedCleanly = pipeline.finish()
        XCTAssertTrue(recordingClosedCleanly, "A close/synchronize failure must fail the recording acceptance")
        let closeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopBegan) * 1_000
        let pingStats = try await pings
        let retainedMic = try XCTUnwrap(pipeline.micRecordingURL)
        let retainedSystem = try XCTUnwrap(pipeline.systemRecordingURL)
        let micProof = try Self.hashAudio(retainedMic)
        let systemProof = try Self.hashAudio(retainedSystem)
        let expectedMicHash = Self.hex(expectedMic.finalize())
        let expectedSystemHash = Self.hex(expectedSystem.finalize())
        let expectedFrames = Int64(totalBlocks * frameCount)
        let finalRSS = Self.residentBytes()
        peakRSS = max(peakRSS, finalRSS)
        var result: [String: Any] = [
            "state": "complete", "wall_seconds": wallSeconds, "seconds_requested": seconds,
            "cadence": cadence, "playback_seconds": Double(expectedFrames) / 16_000,
            "scheduling_metrics_available": !accelerated,
            "blocks_per_leg": totalBlocks, "frames_per_leg": expectedFrames,
            "paused_blocks": pausedBlocks, "late_blocks": lateBlocks,
            "callback_ms": callbackTiming.json, "scheduler_lag_ms": schedulingLag.json,
            "independent_main_actor_ping_ms": pingStats.json, "transcript_publish_ms": transcriptPublishTiming.json,
            "initial_rss_bytes": initialRSS, "final_rss_bytes": finalRSS, "peak_sampled_rss_bytes": peakRSS,
            "cpu_seconds": captureCPU, "total_cpu_seconds_including_verification": Self.cpuSeconds() - initialCPU, "close_flush_ms": closeMilliseconds,
            "system_start_offset_ms": systemOffsetMs, "transcript_entries": transcript.liveEntries.count,
            "injected_final_word_count": callbackWordCount, "fatal_errors": fatalErrors, "provider_errors": providerErrors,
            "mic": ["path": retainedMic.path, "frames": micProof.frames, "sha256": micProof.sha256, "expected_sha256": expectedMicHash],
            "system": ["path": retainedSystem.path, "frames": systemProof.frames, "sha256": systemProof.sha256, "expected_sha256": expectedSystemHash],
            "samples": snapshots,
            "recording_closed_cleanly": recordingClosedCleanly,
            "verified_pcm_integrity": micProof.sha256 == expectedMicHash && systemProof.sha256 == expectedSystemHash && micProof.frames == expectedFrames && systemProof.frames == expectedFrames,
            "scope": "Metrics include XCTest and injected PCM generation. Pipeline logs use a no-op sink. No physical capture, live provider or full UI rendering."
        ]
        if accelerated {
            result["scheduler_lag_ms"] = NSNull()
            result["independent_main_actor_ping_ms"] = NSNull()
            result["late_blocks"] = NSNull()
            result["scope"] = "Accelerated workload and retained-byte verification only. No realtime responsiveness or physical-device-health claim. Capture, STT and pipeline logs are injected."
        }
        try writeJSON(result, to: directory.appendingPathComponent("result.json"))
        XCTAssertTrue(fatalErrors.isEmpty, "\(fatalErrors)")
        XCTAssertTrue(providerErrors.isEmpty, "\(providerErrors)")
        XCTAssertEqual(micProof.frames, expectedFrames)
        XCTAssertEqual(systemProof.frames, expectedFrames)
        XCTAssertEqual(micProof.sha256, expectedMicHash)
        XCTAssertEqual(systemProof.sha256, expectedSystemHash)
        if !accelerated { XCTAssertGreaterThanOrEqual(wallSeconds, seconds) }
        XCTAssertGreaterThan(callbackWordCount, 0)
        XCTAssertGreaterThan(initialRSS, 0, "Mach process metrics must be available")
    }

    @MainActor
    private struct Source {
        let url: URL
        let samples: [Int16]
        let sha256: String
        init(url: URL) throws {
            self.url = url
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.length > 0, file.length <= 16_000 * 120 else {
                throw NSError(domain: "PipelineEndurance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Fixture must be mono 16kHz WAV, nonempty and at most 120 seconds"])
            }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            samples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
            sha256 = RealTimePipelineEnduranceTests.hex(SHA256.hash(data: try Data(contentsOf: url)))
        }
        func buffer(startFrame: Int, frameCount: Int) throws -> AVAudioPCMBuffer {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioCaptureManager.targetFormat, frameCapacity: AVAudioFrameCount(frameCount)))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for index in 0..<frameCount { buffer.int16ChannelData![0][index] = samples[(startFrame + index) % samples.count] }
            return buffer
        }
    }

    /// Fixed bins keep memory independent of session duration. Quantiles are
    /// the upper bound of the containing bin, in milliseconds.
    private struct Histogram: Sendable {
        static let limits: [Double] = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 20, 32, 64, 128, 256, 512, 1_024, 10_000]
        var bins = Array(repeating: 0, count: limits.count + 1)
        var count = 0
        var sum: Double = 0
        var maximum: Double = 0
        mutating func record(_ milliseconds: Double) {
            bins[Self.limits.firstIndex(where: { milliseconds <= $0 }) ?? Self.limits.count] += 1
            count += 1
            sum += milliseconds
            maximum = max(maximum, milliseconds)
        }
        func quantile(_ fraction: Double) -> Double {
            let target = max(1, Int(ceil(Double(count) * fraction)))
            var seen = 0
            for (index, bin) in bins.enumerated() {
                seen += bin
                if seen >= target { return index < Self.limits.count ? Self.limits[index] : maximum }
            }
            return 0
        }
        var json: [String: Any] {
            ["count": count, "mean": count == 0 ? 0 : sum / Double(count), "max": maximum,
             "p50_upper_bound": quantile(0.5), "p95_upper_bound": quantile(0.95), "p99_upper_bound": quantile(0.99)]
        }
    }

    private static func schedulerPings(startedAt: Double, seconds: Double) async throws -> Histogram {
        var histogram = Histogram()
        var offset = 1.0
        while offset < seconds {
            let deadline = startedAt + offset
            let wait = deadline - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            histogram.record(max(0, ProcessInfo.processInfo.systemUptime - deadline) * 1_000)
            offset += 1
        }
        return histogram
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func bytes(_ buffer: AVAudioPCMBuffer) -> Data {
        Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
    }

    private static func hashAudio(_ url: URL) throws -> (frames: Int64, sha256: String) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        var hash = SHA256()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            hash.update(data: bytes(buffer))
        }
        return (file.length, hex(hash.finalize()))
    }

    private static func word(_ text: String, ms: Int, language: String) -> SonioxWord {
        SonioxWord(text: text, startMs: ms, endMs: ms + 900, speaker: 0, confidence: 1,
                   isFinal: true, translationStatus: "none", language: language, sourceLanguage: nil)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
