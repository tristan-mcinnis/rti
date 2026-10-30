# Recording acceptance, 2026-10-30

This benchmark uses invented English and Mandarin speech generated locally. No meeting audio, microphone capture, network provider, credentials or permission changes are involved. The component run is not a claim of commercial-product quality.

## Reproduce

From the RTI repository, create a new fixture folder:

```sh
python3 scripts/make-recording-acceptance-fixtures.py --output /tmp/rti-acceptance-new/fixtures
python3 scripts/recording-writer-benchmark.py --seconds 7200 --realtime --mic-wav /tmp/rti-acceptance-new/fixtures/mic.wav --system-wav /tmp/rti-acceptance-new/fixtures/system.wav --output /tmp/rti-writer-new
```

The writer runner compiles the actual WAVWriter and AudioFormat source, checks exclusive creation and unsupported formats, kills only its invented-data child after a completed append, and injects bounded file-size exhaustion in another child. It verifies complete replay bytes and WAV frame counts. It does not fill the disk.

Run the opt-in pipeline test with a distinct build/artifact directory. The TEST_RUNNER_ forms pass values through Xcode to XCTest:

```sh
export RTI_PIPELINE_ENDURANCE_SECONDS=7200
export TEST_RUNNER_RTI_PIPELINE_ENDURANCE_SECONDS=7200
export RTI_PIPELINE_ENDURANCE_ARTIFACT_DIR=/tmp/rti-pipeline-new
export TEST_RUNNER_RTI_PIPELINE_ENDURANCE_ARTIFACT_DIR=/tmp/rti-pipeline-new
export RTI_PIPELINE_ENDURANCE_MIC_WAV=/tmp/rti-acceptance-new/fixtures/mic.wav
export TEST_RUNNER_RTI_PIPELINE_ENDURANCE_MIC_WAV="$RTI_PIPELINE_ENDURANCE_MIC_WAV"
export RTI_PIPELINE_ENDURANCE_SYSTEM_WAV=/tmp/rti-acceptance-new/fixtures/system.wav
export TEST_RUNNER_RTI_PIPELINE_ENDURANCE_SYSTEM_WAV="$RTI_PIPELINE_ENDURANCE_SYSTEM_WAV"
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug -derivedDataPath .deriveddata-tests test -only-testing:RTIRenderTests/RealTimePipelineEnduranceTests/testTwoLegsAtRealTimeCadence
python3 scripts/recording-acceptance-report.py --writer /tmp/rti-writer-new --pipeline /tmp/rti-pipeline-new --output /tmp/rti-acceptance-report.json
```

Set both RTI_PIPELINE_ENDURANCE_ACCELERATED=1 and TEST_RUNNER_RTI_PIPELINE_ENDURANCE_ACCELERATED=1 to opt into accelerated workload replay. Its receipt separates playback_seconds from wall_seconds and suppresses cadence/ping metrics. The measured repaired real-time run used 900 seconds; the separate accelerated run used 7,200 playback seconds. Use a new artifact directory for every run.

The pipeline fixture injects two capture sources at 50 callbacks per second and transcription tokens through the actual AudioPipeline, MeetingRecorder and TranscriptPipeline. It hashes both retained legs with SHA-256, verifies frame counts and pause silence, and measures process CPU, resident memory, callback duration, scheduler delay and transcript publication. No provider requests are made. Without the duration environment value, the test skips. Use a separate DerivedData directory for other tests while this run is active.

## Evidence and repairs

| Case | Observed outcome |
| --- | --- |
| Existing/symlink audio destination | Baseline overwrote existing audio; repaired writer refuses and preserves it |
| Unsupported PCM | Repaired writer reports failure |
| Bounded write failure | Baseline WAV length mismatch; repair rolls back the failed append and reports it |
| Process killed after completed append | Retained WAV opens and matches completed frames |
| Transcription network/auth failure | Local capture continues; each failed leg recovers independently |
| Microphone rebound or system-start failure | Grace interval and health reflect actual capture callbacks; errors are explicit |
| Audio close failure | Synchronous failure latch prevents false Saved state and automatic upgrade |
| Archive path/write collision | Returns failure, preserves source audio and existing destination |
| Close failure plus archive failure | Removes automatic-work marker before archive attempt; audio remains untouched |
| Damaged archive with known recording error | Persistent Recording needs review label; excluded from automatic processing |

Focused suites: RecordingWriterAcceptanceTests, MeetingRecorderTests, AudioPipelineRecoveryTests, SessionArchiveRecoveryTests and SessionCaptureFailurePolicyTests. The latter also renders recovery controls at the shared minimum size in both appearances. Tests isolate configuration, archives and logs from the real app. Independent review checked the integrated failure policy.

## Limits and metric interpretation

The real-time writer run passed 7,200 playback seconds in 7,199.985 measured wall seconds (the first block is immediate). Its 707,970 append calls retained the expected per-leg frame counts, pause silence and FNV-1a byte hashes, with zero write failures. Append p95 was 0.140 ms, p99 0.419 ms and maximum 101.978 ms; maximum synthetic schedule lateness was 197.622 ms on the shared host. The writer receipt is under /tmp/rti-writer-two-hour-20261030. The repaired pipeline receipts are /tmp/rti-recording-acceptance-20261030/pipeline-final-15m and pipeline-final-accelerated-2h. Source-hash manifests accompany the runs. The original Debug/MainActor baseline was stopped after 79 measured minutes once the production merge bottleneck was diagnosed. Its progress and stopped.json are retained under pipeline-2h. It is not a completed PCM acceptance run.

The repaired real-time run retained 14,400,000 frames per leg over 900.006 wall seconds, with exact SHA-256 matches and clean close. Process CPU was 23.79 seconds (2.64% of one core); sampled peak RSS was 44.3 MiB. Independent MainActor ping maximum was 53.1 ms, with a histogram p95 upper bound of 32 ms. These are XCTest process measurements on a shared host.

The full accelerated run retained 115,200,000 frames per leg across 7,200 playback seconds in 605.714 wall seconds. Both SHA-256 hashes matched, all 720,000 callbacks were processed, 1,800 pause blocks were included, and 14,328 final transcript entries remained. Close was clean and fatal/provider error arrays were empty. This verifies the complete workload, not real-time deadlines.

The final integrated run passed 95 checks. The earlier transcript/aggregation/presentation/turn run passed 70 checks; these counts overlap. Minimum-size light and dark renders of the actual workspace with 14,400 invented entries were inspected. Independent reviewers cleared the failure policy, cache invalidation and accelerated-mode semantics.

The original writer run field append_cpu_seconds measures wall duration around append, including I/O. It is not CPU. The report names this correctly and future harness runs emit append_wall_seconds. Pipeline CPU includes XCTest, speech generation and hash computation. Host builds can affect scheduling. Stable memory or exact final bytes alone do not establish responsiveness.

Physical microphone/system-device behaviour, real recognition accuracy, backend callback queue safety, full installed-app rendering under a two-hour load, sudden power loss and a kill during header rewrite remain unverified. The production system-capture startup delay is eight seconds; this fixture sets it to zero. These gaps must stay visible in any release-quality claim.

## Transcript projection performance

An optimized standalone driver reproduced the long-session merge cost in production code. It uses identical compiler flags for baseline and repair, captures source hashes and compiler commands, and compares all 89 full semantic snapshots, including late/reordered streams, translations, corrections, reset/reconnect and echo trimming.

At 14,424 entries, steady merge mean fell from 562 ms to 24.03 ms; p95 fell from 733 ms to 25.22 ms. CPU across 24 updates fell from 12.591 s to 0.574 s, a 21.9-fold reduction. Cold merge fell from 529 ms to 352 ms. Output snapshots match exactly. The gate requires at least a two-fold CPU improvement. A strict 20 ms steady-merge target remains unmet.

```sh
git show aacff7b2:RTI/Core/Session/TranscriptPipeline.swift > /tmp/transcript-baseline.swift
python3 scripts/transcript-merge-benchmark.py --output /tmp/transcript-baseline --pipeline-source /tmp/transcript-baseline.swift
python3 scripts/transcript-merge-benchmark.py --output /tmp/transcript-repaired --reference /tmp/transcript-baseline/result.json
```

The paused-outage regression also checks that Retry keeps the session suspended, retains only silence, and says Recording remains paused. The source hashes of the full accelerated run match the final production writer, audio pipeline and transcript pipeline. The 15-minute real-time run predates only that paused-state copy change.

## Writer memory measurement

The historical two-hour writer receipt reports a 474,169,344-byte verification-inclusive peak. A matched 600-second investigation measured 14,843,904 bytes before verification and 53,002,240 bytes after verification. Per-chunk FileHandle reads accumulated autoreleased Foundation buffers in the standalone harness. A per-read autorelease pool reduced the matched run to 14,811,136 bytes during recording and 16,138,240 bytes overall, with identical frame counts and PCM hashes. Production writer code did not change. New harness receipts separate recording-phase peak RSS; the historical raw receipt remains unchanged. This is not an installed-app memory measurement. Evidence: /tmp/rti-writer-rss-comparison-20261030.json.

## Consolidated receipt

```sh
python3 scripts/recording-acceptance-report.py --writer /tmp/rti-writer-two-hour-20261030 --pipeline /tmp/rti-recording-acceptance-20261030/pipeline-final-15m --pipeline-accelerated /tmp/rti-recording-acceptance-20261030/pipeline-final-accelerated-2h --pipeline-baseline /tmp/rti-recording-acceptance-20261030/pipeline-2h --output /tmp/rti-recording-acceptance-20261030/summary.json
```

The report requires complete writer, repaired real-time and accelerated results before reporting complete. Its PCM pass also requires both repaired pipeline integrity flags and clean closes. Historical stopped-baseline measurements remain separate and cannot become a PCM pass. Recovery assertions are supported separately by the executed regression suites. Final delivery requires a clean published revision, matching installed/built bytes and plist, valid stable signature, one installed process and a healthy control socket; receipt: /tmp/rti-recording-acceptance-20261030/delivery.json.
