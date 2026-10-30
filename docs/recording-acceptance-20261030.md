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

Two-hour run receipts live under /tmp/rti-writer-two-hour-20261030 and /tmp/rti-recording-acceptance-20261030/pipeline-2h. Runs are in progress at this commit. The writer source has not changed since launch. The pipeline binary predates the later close-failure latch; final error policy has separate deterministic regression coverage.

The original writer run field append_cpu_seconds measures wall duration around append, including I/O. It is not CPU. The report names this correctly and future harness runs emit append_wall_seconds. Pipeline CPU includes XCTest, speech generation and hash computation. Host builds can affect scheduling. Stable memory or exact final bytes alone do not establish responsiveness.

Physical microphone/system-device behaviour, real recognition accuracy, backend callback queue safety, full installed-app rendering under a two-hour load, sudden power loss and a kill during header rewrite remain unverified. The production system-capture startup delay is eight seconds; this fixture sets it to zero. These gaps must stay visible in any release-quality claim.
