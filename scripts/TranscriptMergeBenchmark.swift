import CryptoKit
import Darwin
import Foundation

/// Compile with the real Foundation-only transcript sources. This driver does
/// not open the app, audio devices, storage owners, or any provider.
@main
struct TranscriptMergeBenchmark {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 2 || arguments.count == 3 else { throw Failure("expected output JSON and optional baseline JSON") }
            if ProcessInfo.processInfo.environment["RTI_TRANSCRIPT_MERGE_PROFILE"] == "1" {
                try write(["profile": "optimized extended steady window", "measurements": [measure(seconds: 7_200, additionalSeconds: 300)]], path: arguments[1])
                return
            }
            let snapshots = equivalenceSnapshots()
            let snapshotData = try JSONSerialization.data(withJSONObject: snapshots, options: [.sortedKeys])
            let digest = SHA256.hash(data: snapshotData).map { String(format: "%02x", $0) }.joined()
            var measurements: [[String: Any]] = []
            for seconds in [600, 2_400, 7_200] { measurements.append(measure(seconds: seconds)) }
            var receipt: [String: Any] = [
                "profile": "swift6 -O, actual production transcript sources, macOS14 target",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "equivalence_sha256": digest, "snapshot_count": snapshots.count,
                "snapshots": snapshots, "measurements": measurements
            ]
            if arguments.count == 3 {
                let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
                let equivalent = baseline["equivalence_sha256"] as? String == digest
                receipt["equivalent_to_baseline"] = equivalent
                try write(receipt, path: arguments[1])
                guard equivalent else { throw Failure("semantic snapshots differ from baseline") }
            } else { try write(receipt, path: arguments[1]) }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("transcript-merge-benchmark: \(error)\n".utf8))
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func write(_ object: [String: Any], path: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func word(_ text: String, ms: Int, speaker: Int = 0, status: String = "none", language: String = "en", final: Bool = true) -> SonioxWord {
        SonioxWord(text: text, startMs: ms, endMs: ms + 400, speaker: speaker, confidence: 0.9,
                   isFinal: final, translationStatus: status, language: language, sourceLanguage: status == "translation" ? "zh" : nil)
    }

    static func measure(seconds: Int, additionalSeconds: Int = 12) -> [String: Any] {
        let pipeline = TranscriptPipeline()
        for second in 0..<seconds {
            pipeline.process(words: [word("Synthetic English microphone segment \(second). ", ms: second * 1_000)], channel: "mic")
            pipeline.process(words: [word("合成普通话系统声音片段\(second)。", ms: second * 1_000, language: "zh")], channel: "system")
        }
        let coldBegan = ProcessInfo.processInfo.systemUptime
        _ = pipeline.liveEntries
        let coldMs = (ProcessInfo.processInfo.systemUptime - coldBegan) * 1_000
        var durations: [Double] = []
        let cpuBegan = cpuSeconds()
        for second in seconds..<(seconds + additionalSeconds) {
            for channel in ["mic", "system"] {
                let token = channel == "mic"
                    ? word("Synthetic English microphone segment \(second). ", ms: second * 1_000)
                    : word("合成普通话系统声音片段\(second)。", ms: second * 1_000, language: "zh")
                let begin = ProcessInfo.processInfo.systemUptime
                pipeline.process(words: [token], channel: channel)
                _ = pipeline.liveEntries
                durations.append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
            }
        }
        let cpu = cpuSeconds() - cpuBegan
        let ordered = durations.sorted()
        return ["fixture_seconds": seconds, "entries": pipeline.liveEntries.count, "cold_merge_ms": coldMs,
                "updates": durations.count, "steady_cpu_seconds": cpu,
                "steady_mean_ms": durations.reduce(0, +) / Double(durations.count),
                "steady_p95_ms": ordered[Int((Double(ordered.count) * 0.95).rounded(.up)) - 1],
                "steady_max_ms": ordered[ordered.count - 1]]
    }

    /// UUIDs are represented by first-appearance ordinals, so identity and
    /// correction lineage remain testable without depending on random values.
    static func equivalenceSnapshots() -> [[String: Any]] {
        let pipeline = TranscriptPipeline()
        var ids: [UUID: Int] = [:]
        var streams: [UUID: Int] = [:]
        var snapshots: [[String: Any]] = []
        func ordinal(_ value: UUID?, map: inout [UUID: Int]) -> Int {
            guard let value else { return -1 }
            if let existing = map[value] { return existing }
            let next = map.count
            map[value] = next
            return next
        }
        func snapshot(_ tag: String) {
            let entries: [[String: Any]] = pipeline.liveEntries.map { entry in
                let origin: String
                let continuing: Int
                switch entry.textOrigin {
                case .standalone: origin = "standalone"; continuing = -1
                case .providerTokens: origin = "providerTokens"; continuing = -1
                case .providerCorrection(let stream): origin = "providerCorrection"; continuing = ordinal(stream, map: &streams)
                }
                return ["id": ordinal(entry.id, map: &ids), "speaker": entry.speakerId, "text": entry.text,
                        "start": entry.startMs, "confidence": entry.confidence, "status": entry.translationStatus,
                        "language": entry.language ?? "", "source_language": entry.sourceLanguage ?? "",
                        "origin": origin, "continuing": continuing, "stream": ordinal(entry.streamID, map: &streams),
                        "display_stream": ordinal(entry.displayStreamID, map: &streams),
                        "tokens": entry.tokens.map { ["text": $0.text, "start": $0.startMs, "end": $0.endMs] as [String: Any] }]
            }
            let interims: [[String: Any]] = pipeline.interimSegments.map {
                ["text": $0.text, "speaker": $0.speakerId, "start": $0.startMs ?? -1,
                 "stream": ordinal($0.streamID, map: &streams), "language": $0.language ?? ""]
            }
            snapshots.append(["tag": tag, "entries": entries, "interim": pipeline.interimLine ?? "", "segments": interims])
        }
        pipeline.process(words: [word("alpha beta gamma", ms: 2_000)], channel: "mic")
        snapshot("mic_before_late_system")
        pipeline.process(words: [word("alpha beta", ms: 1_800), word(" gamma", ms: 2_250)], channel: "system")
        snapshot("late_system_changes_old_mic_coverage")
        pipeline.process(words: [word("你好，世界。", ms: 4_000, speaker: 2, language: "zh")], channel: "mic")
        snapshot("mandarin_mic")
        pipeline.process(words: [word("你好", ms: 3_800, language: "zh"), word("，世界。", ms: 4_250, language: "zh")], channel: "system")
        snapshot("late_mandarin_system")
        pipeline.process(words: [word("translated text", ms: 5_000, status: "translation")], channel: "system")
        pipeline.process(words: [word("interim only", ms: 5_500, final: false)], channel: "mic")
        snapshot("translation_and_interim")
        pipeline.process(words: [word("Café e\u{301}lan ΟΣ 👩🏽‍💻", ms: 7_000, speaker: 2)], channel: "mic")
        pipeline.process(words: [word("CAFÉ e\u{301}lan ΟΣ 👩🏽‍💻", ms: 6_700)], channel: "system")
        snapshot("unicode_context")
        pipeline.restartStream(channel: "system", atMs: 1_500)
        pipeline.process(words: [word("alpha beta gamma delta", ms: 0)], channel: "system")
        snapshot("out_of_order_restarted_system")
        pipeline.restartStream(channel: "mic", atMs: 20_000)
        pipeline.process(words: [word("fresh microphone", ms: 0)], channel: "mic")
        snapshot("mic_reconnect")
        pipeline.insertNote("A synthetic note", startedAt: Date().addingTimeInterval(-1))
        // Note wall time is deliberately excluded from the deterministic trace.
        pipeline.reset()
        snapshot("reset")
        pipeline.prepareForReconnect()
        for index in 0..<80 {
            let text = index % 3 == 0 ? "共同句子 \(index)" : "independent words \(index)"
            let channel = index.isMultiple(of: 2) ? "mic" : "system"
            pipeline.process(words: [word(text, ms: index * 800, speaker: index % 4)], channel: channel)
            if index.isMultiple(of: 5) {
                pipeline.restartStream(channel: channel == "mic" ? "system" : "mic", atMs: max(0, index * 800 - 2_000))
                pipeline.process(words: [word(text, ms: 0, speaker: index % 3)], channel: channel == "mic" ? "system" : "mic")
            }
            snapshot("mixed_\(index)")
        }
        return snapshots
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
