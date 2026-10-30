import AVFoundation
import Darwin
import Foundation

/// A hardware-free executable compiled with the unchanged production writer.
/// Each accepted block is checked against deterministic invented PCM bytes.
@main
struct RecordingWriterBenchmark {
    static let framesPerBlock = 320
    static let blocksPerSecond = 50

    static func main() {
        do { try run() } catch {
            try? FileHandle.standardError.write(contentsOf: Data("writer-benchmark: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        CoreLog.installSink { _, _ in }
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw Failure("missing mode or fixture directory") }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch arguments[1] {
        case "probes": try probes(in: directory)
        case "crash-child": try crashChild(in: directory)
        case "verify-crash": try verifyCrash(in: directory)
        case "write-failure": try writeFailure(in: directory)
        case "replay":
            guard arguments.count == 7, let seconds = Int(arguments[3]), (1...7200).contains(seconds) else {
                throw Failure("invalid replay duration")
            }
            let sources = try arguments[5...6].map { try sourcePCM(path: $0) }
            try replay(in: directory, seconds: seconds, realtime: arguments[4] == "realtime", sources: sources)
        default: throw Failure("unknown mode")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    static func writeJSON(_ object: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
    }

    static func buffer(block: Int, leg: Int, count: Int = framesPerBlock, source: [Int16]? = nil) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            buffer.int16ChannelData![0][index] = source.map { $0[(block * framesPerBlock + index) % $0.count] }
                ?? Int16((block * 17 + index * 13 + leg * 101) % 60_001 - 30_000)
        }
        // Four samples identify the leg and exact second, without obscuring
        // the spoken fixture. Paused intervals intentionally replace them too.
        if source != nil, block % blocksPerSecond == 0, count >= 4 {
            buffer.int16ChannelData![0][0] = -30_000
            buffer.int16ChannelData![0][1] = Int16(leg)
            buffer.int16ChannelData![0][2] = Int16(block / blocksPerSecond)
            buffer.int16ChannelData![0][3] = 30_000
        }
        return buffer
    }

    static func sourcePCM(path: String) throws -> [Int16]? {
        guard path != "-" else { return nil }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: true)
        try require(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1,
                    "speech fixtures must be 16 kHz mono")
        try require(file.length > 0 && file.length <= 16_000 * 600, "speech fixture must contain 0...600 seconds")
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: output)
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }

    static func bytes(_ buffer: AVAudioPCMBuffer) -> Data {
        Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
    }

    static func payload(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        try require(data.count >= 44, "WAV is missing header")
        try require(data.prefix(4) == Data("RIFF".utf8), "invalid RIFF signature")
        try require(data[36..<40] == Data("data".utf8), "unexpected WAV layout")
        let length = data[40..<44].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        try require(Int(length) == data.count - 44, "header/payload length mismatch")
        let file = try AVAudioFile(forReading: url)
        try require(file.length == Int64(length / 2), "AVAudioFile disagrees with PCM length")
        return data.dropFirst(44)
    }

    static func probes(in root: URL) throws {
        let directory = root.appendingPathComponent("probes", isDirectory: true)
        let recorder = MeetingRecorder()
        var failures: [String] = []
        recorder.onWriteFailure = { failures.append($0) }
        try recorder.open(in: directory)
        let before = buffer(block: 0, leg: 1)
        let paused = buffer(block: 1, leg: 1)
        let after = buffer(block: 2, leg: 1)
        recorder.appendMic(before)
        recorder.appendMicSilence(matching: paused)
        recorder.appendMic(after)
        recorder.appendSystem(buffer(block: 0, leg: 2, count: 113))
        recorder.close()
        let mic = directory.appendingPathComponent("audio-mic.wav")
        let expected = bytes(before) + Data(count: framesPerBlock * 2) + bytes(after)
        try require(try payload(at: mic) == expected, "pause/resume changed timestamp markers")
        try require(try payload(at: directory.appendingPathComponent("audio-system.wav")).count == 226,
                    "unequal leg lost its independent frame count")
        let original = try Data(contentsOf: mic)
        var collisionRejected = false
        do { try recorder.open(in: directory) } catch { collisionRejected = true }
        recorder.close()
        let existingAudioPreserved = (try? Data(contentsOf: mic)) == original

        let invalid = root.appendingPathComponent("invalid-format", isDirectory: true)
        try recorder.open(in: invalid)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        let badBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        badBuffer.frameLength = 32
        recorder.appendMic(badBuffer)
        let unsupportedFormatReported = failures.count == 1
        recorder.close()
        try writeJSON(["passed": collisionRejected && existingAudioPreserved && unsupportedFormatReported,
                       "pause_frames": 320, "mic_frames": 960, "system_frames": 113,
                       "existing_audio_preserved": existingAudioPreserved,
                       "collision_rejected": collisionRejected, "unsupported_format_reported": unsupportedFormatReported],
                      at: root.appendingPathComponent("probes.json"))
        try require(collisionRejected && existingAudioPreserved && unsupportedFormatReported,
                    "existing-file preservation or unsupported-format reporting failed; see probes.json")
    }

    static func crashChild(in directory: URL) throws {
        let recorder = MeetingRecorder()
        try recorder.open(in: directory)
        for block in 0..<50 {
            recorder.appendMic(buffer(block: block, leg: 1))
            recorder.appendSystem(buffer(block: block, leg: 2))
        }
        try writeJSON(["completed_blocks": 50], at: directory.appendingPathComponent("ready.json"))
        // Parent kills only this child after ready.json; no recorder.close().
        while true { Thread.sleep(forTimeInterval: 0.1) }
    }

    static func verifyCrash(in directory: URL) throws {
        for (leg, name) in [(1, "audio-mic.wav"), (2, "audio-system.wav")] {
            var expected = Data()
            for block in 0..<50 { expected.append(bytes(buffer(block: block, leg: leg))) }
            try require(try payload(at: directory.appendingPathComponent(name)) == expected,
                        "SIGKILL lost or changed completed blocks for \(name)")
        }
        try writeJSON(["passed": true, "frames_per_leg": 16_000, "termination": "SIGKILL",
                       "scope": "after append returned; excludes power loss and kill during header rewrite"],
                      at: directory.appendingPathComponent("metrics.json"))
    }

    static func writeFailure(in directory: URL) throws {
        let recorder = MeetingRecorder()
        var failures: [String] = []
        recorder.onWriteFailure = { failures.append($0) }
        try recorder.open(in: directory)
        let first = buffer(block: 0, leg: 1)
        recorder.appendMic(first)
        var originalLimit = rlimit()
        guard getrlimit(RLIMIT_FSIZE, &originalLimit) == 0 else { throw Failure("getrlimit failed") }
        var boundedLimit = rlimit(rlim_cur: 1024, rlim_max: originalLimit.rlim_max)
        let originalSignal = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, originalSignal) }
        guard setrlimit(RLIMIT_FSIZE, &boundedLimit) == 0 else { throw Failure("setrlimit failed") }
        recorder.appendMic(buffer(block: 1, leg: 1, count: 2000))
        guard setrlimit(RLIMIT_FSIZE, &originalLimit) == 0 else { throw Failure("restore rlimit failed") }
        let after = buffer(block: 2, leg: 1)
        recorder.appendMic(after)
        recorder.close()
        let actual = try? payload(at: directory.appendingPathComponent("audio-mic.wav"))
        let partialWriteRolledBack = actual == bytes(first) + bytes(after)
        try writeJSON(["passed": failures.count == 1 && partialWriteRolledBack,
                       "fault": "child-only RLIMIT_FSIZE=1024", "failure_callbacks": failures.count,
                       "retained_frames": (actual?.count ?? 0) / 2, "partial_write_rolled_back": partialWriteRolledBack],
                      at: directory.appendingPathComponent("metrics.json"))
        try require(failures.count == 1, "write failure was not reported exactly once")
        try require(partialWriteRolledBack, "partial failed write contaminated later audio")
    }

    static func hash(_ data: Data, into value: inout UInt64) {
        for byte in data { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    static func replay(in directory: URL, seconds: Int, realtime: Bool, sources: [[Int16]?]) throws {
        let recorder = MeetingRecorder()
        var failures: [String] = []
        recorder.onWriteFailure = { failures.append($0) }
        try recorder.open(in: directory)
        let totalBlocks = seconds * blocksPerSecond
        var expectedHashes = [UInt64](repeating: 14_695_981_039_346_656_037, count: 2)
        var frames = [0, 0]
        var pauseFrames = [0, 0]
        var maxAppendNs: UInt64 = 0
        var appendNs: UInt64 = 0
        var appendTimesNs: [UInt64] = []
        appendTimesNs.reserveCapacity(totalBlocks * 2)
        var maximumScheduleLatenessNs: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for block in 0..<totalBlocks {
            if realtime {
                let target = start + UInt64(block) * 20_000_000
                let now = DispatchTime.now().uptimeNanoseconds
                if target > now { Thread.sleep(forTimeInterval: Double(target - now) / 1_000_000_000) }
                let actual = DispatchTime.now().uptimeNanoseconds
                maximumScheduleLatenessNs = max(maximumScheduleLatenessNs, actual > target ? actual - target : 0)
            }
            let paused = (block / blocksPerSecond) % 60 >= 11 && (block / blocksPerSecond) % 60 < 13
            for leg in 0..<2 {
                // The system starts 600 ms late and has a two-second callback
                // gap per minute. Missing callbacks stay visible as shorter PCM.
                if leg == 1 && (block < 30 || (47..<49).contains((block / blocksPerSecond) % 60)) { continue }
                let input = buffer(block: block, leg: leg + 1, source: sources[leg])
                let begin = DispatchTime.now().uptimeNanoseconds
                if leg == 0 {
                    if paused { recorder.appendMicSilence(matching: input) } else { recorder.appendMic(input) }
                } else {
                    if paused { recorder.appendSystemSilence(matching: input) } else { recorder.appendSystem(input) }
                }
                let cost = DispatchTime.now().uptimeNanoseconds - begin
                appendNs += cost
                appendTimesNs.append(cost)
                maxAppendNs = max(maxAppendNs, cost)
                frames[leg] += framesPerBlock
                if paused { pauseFrames[leg] += framesPerBlock }
                hash(paused ? Data(count: framesPerBlock * 2) : bytes(input), into: &expectedHashes[leg])
            }
            if block % 250 == 0 || block == totalBlocks - 1 {
                try writeJSON(["state": "running", "completed_blocks": block + 1, "total_blocks": totalBlocks,
                               "audio_seconds": Double(block + 1) / 50, "frames": frames,
                               "write_failures": failures.count,
                               "elapsed_seconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000],
                              at: directory.appendingPathComponent("progress.json"))
            }
        }
        recorder.close()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        try require(failures.isEmpty, "replay reported write failures")
        var recordingUsage = rusage()
        getrusage(RUSAGE_SELF, &recordingUsage)
        var actualHashes: [String] = []
        for (leg, name) in ["audio-mic.wav", "audio-system.wav"].enumerated() {
            let url = directory.appendingPathComponent(name)
            let file = try AVAudioFile(forReading: url)
            try require(file.length == Int64(frames[leg]), "replay frame count differs for \(name)")
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 44)
            var actual: UInt64 = 14_695_981_039_346_656_037
            // Foundation's read can return autoreleased backing storage.
            // Release each chunk before reading the next one so verification
            // does not retain a copy of the entire two-hour WAV payload.
            while try autoreleasepool(invoking: {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                hash(data, into: &actual)
                return true
            }) {}
            try require(actual == expectedHashes[leg], "PCM byte hash differs for \(name)")
            actualHashes.append(String(actual, radix: 16))
        }
        appendTimesNs.sort()
        func percentile(_ fraction: Double) -> Double {
            Double(appendTimesNs[min(appendTimesNs.count - 1, Int(Double(appendTimesNs.count - 1) * fraction))]) / 1_000_000
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let metrics: [String: Any] = [
            "state": "passed", "synthetic_duration_seconds": seconds, "realtime": realtime,
            "elapsed_seconds": elapsed, "frames": frames, "pause_silence_frames": pauseFrames,
            "pcm_fnv1a64": actualHashes, "write_failures": failures.count,
            "append_wall_seconds": Double(appendNs) / 1_000_000_000,
            "append_calls": appendTimesNs.count,
            "p50_append_ms": percentile(0.50), "p95_append_ms": percentile(0.95),
            "p99_append_ms": percentile(0.99), "maximum_schedule_lateness_ms": Double(maximumScheduleLatenessNs) / 1_000_000,
            "process_peak_rss_bytes": usage.ru_maxrss,
            "recording_phase_peak_rss_bytes": recordingUsage.ru_maxrss,
            "output_bytes": frames.reduce(88) { $0 + $1 * 2 },
            "source_frames": sources.map { $0?.count ?? 0 },
            "source_shape": "optional invented speech, looped with four-sample leg/second markers",
            "max_append_ms": Double(maxAppendNs) / 1_000_000,
            "scope": "real production WAV writer only; no hardware, capture resampling, sockets or app lifecycle",
        ]
        try writeJSON(metrics, at: directory.appendingPathComponent("metrics.json"))
        try writeJSON(metrics, at: directory.appendingPathComponent("progress.json"))
    }
}
