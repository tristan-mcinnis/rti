# Transcript Upgrade Providers

RTI has two distinct speech-to-text lanes:

1. `Real-time transcription`
2. `Transcript upgrade (async)`

They are intentionally separate because they solve different problems.

## Real-time transcription

This is the live, low-latency transcript that powers the overlay while a
meeting is happening.

Properties:

- Must stream continuously with low latency
- Must tolerate reconnects mid-session
- Must feed the live assistant and live analysis tabs
- May trade some absolute accuracy for responsiveness

Current RTI provider: `Soniox` (hosted; live audio leaves the Mac).

Code:

- Provider registry: `RTI/Sources/Soniox/SonioxClient.swift` (`STTProviders`)
- Live pipeline: `RTI/Sources/Audio/AudioPipeline.swift`
- Runtime owner: `RTI/Sources/Session/SessionCoordinator.swift`

## Transcript upgrade (async)

This is the post-hoc lane for `Upgrade Transcript`.

The intent is:

1. Use the retained audio files from the archived RTI session folder
2. Run a slower file/batch transcription provider over those recordings
3. Replace the rough live transcript with the upgraded transcript

Properties:

- Latency is not critical
- Accuracy matters more than streaming responsiveness
- Provider can be language-specialized
- Output is the canonical transcript that the vault reads

Current RTI provider: `Soniox` file transcription, run with English and
Chinese language hints. The Aliyun option was removed on 2026-09-26 (see
below).

Code:

- Provider registry: `RTI/Sources/Soniox/SonioxClient.swift` (`AsyncTranscriptProviders`)
- Settings surface: `RTI/Sources/Settings/KeysTab.swift`
- Upgrade executor: `RTI/Sources/Session/TranscriptUpgradeService.swift`
- Merge/render logic: `RTI/Core/Session/TranscriptUpgrade.swift`
- Durable audio source: session-local `audio-mic.wav` and `audio-system.wav` (older sessions: `.m4a`)

## Why the lanes stay separate

Live capture and the post-hoc upgrade are different jobs: one needs low
latency, the other accuracy. They keep separate registries
(`STTProviders`, `AsyncTranscriptProviders`) even though Soniox serves both
today, so a future batch provider does not inherit the live lane's choice.

## Current product state

The beta sends each retained audio leg through Soniox’s native REST API. It uploads a multipart file, starts an `stt-async-v6` transcription, polls the same job and reads its transcript response. Both legs request language identification and English and Chinese hints, with the meeting's archived Soniox context. Only the system leg can request speaker diarization, controlled by the archived speaker-label setting. [Upload](https://docs.soniox.com/api-reference/stt/files/upload_file) · [Create](https://docs.soniox.com/api-reference/stt/transcriptions/create_transcription) · [Poll](https://docs.soniox.com/api-reference/stt/transcriptions/get_transcription) · [Result](https://docs.soniox.com/api-reference/stt/transcriptions/get_transcription_transcript) · [Model list](https://docs.soniox.com/stt/models)

RTI stores the **exact response bytes** in `soniox-async-mic.json` and `soniox-async-system.json`. Token times are relative to their own uploaded audio. Apply the session’s system-audio start offset once when joining legs. The beta groups contiguous original tokens directly and records each turn’s source filename, token indices, original speaker and leg-relative times in the structured evidence. A missing timestamp stays missing in its source locator and cannot verify a playback anchor. Markdown and the raw text export render the same structured turns. A private per-leg checkpoint records remote IDs until cleanup completes. A retry reuses the saved job or response. After the raw response is written, RTI deletes the remote transcription and then its uploaded file. Earlier recordings with no beta schema or speaker policy keep the file-transcriber path under `soniox_file_script`. [Delete transcription](https://docs.soniox.com/api-reference/stt/transcriptions/delete_transcription) · [Delete file](https://docs.soniox.com/api-reference/stt/files/delete_file)

Aliyun was removed on 2026-09-26. RTI's adapter called an Aliyun NLS script
at `~/Documents/code/archive/aliyun-stt/scripts/aliyun_filetrans.py`, which
went away with the archive tier and is not on GitHub. The Aliyun script that
still exists (`file-transcriber`'s `transcribe-aliyun.py`) is a different
API: it needs a DashScope key and serves the audio from a public HTTP port on
the VPS, which is not acceptable for private meeting audio without a
decision. Soniox already transcribes Chinese.

## Upgrade Transcript Behavior

When RTI runs `Upgrade Transcript`, it:

1. Asks for confirmation (the dialog names the provider)
2. Chooses `audio-mic.wav` and/or `audio-system.wav` (or the older `.m4a`) from the session folder
3. Applies `session.json`'s system-audio offset when merging the two audio legs
4. Runs the provider-specific file transcription adapter
5. Reinserts RTI user notes from the original `transcript.md` by timestamp
6. Saves `transcript.upgraded.md` first
7. Backs up the old `transcript.md` as `transcript.backup-<stamp>.md`
8. Replaces `transcript.md` only after the upgraded artifact succeeds
9. Surfaces progress, errors, provider used, and final status in the Sessions browser

This keeps the live lane fast and the upgrade lane accurate, without conflating
their provider choices.
