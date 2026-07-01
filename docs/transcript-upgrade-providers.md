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

Current RTI provider choices:

- `Soniox` — default live provider
- `AssemblyAI` — alternative live provider

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
4. Regenerate `summary.md` from the upgraded text

Properties:

- Latency is not critical
- Accuracy matters more than streaming responsiveness
- Provider can be language-specialized
- Output should be considered authoritative enough to regenerate the summary

Current RTI provider choices:

- `Aliyun` — preferred default for Chinese-heavy async upgrades
- `Soniox` — alternative for English or mixed English/Chinese upgrades

Code:

- Provider registry: `RTI/Sources/Soniox/SonioxClient.swift` (`AsyncTranscriptProviders`)
- Settings surface: `RTI/Sources/Settings/KeysTab.swift`
- Upgrade executor: `RTI/Sources/Session/TranscriptUpgradeService.swift`
- Merge/render logic: `RTI/Core/Session/TranscriptUpgrade.swift`
- Durable audio source: session-local `audio-mic.m4a` and `audio-system.m4a`

## Why the providers differ

The transcription skill used on this machine already makes this distinction:

- `Realtime`: Soniox
- `Chinese-only file transcription`: Aliyun
- `English or mixed-language file transcription`: Soniox

RTI mirrors that architecture in its provider model so the
`Upgrade Transcript` feature does not inherit the wrong provider from the live
lane.

## Current product state

RTI now stores separate provider choices for:

- Assistant LLM
- Real-time speech-to-text
- Transcript upgrade (async)

Aliyun is not represented as a single opaque API key in RTI. The current
Aliyun file-transcription script requires:

- `ALIBABA_CLOUD_ACCESS_KEY_ID`
- `ALIBABA_CLOUD_ACCESS_KEY_SECRET`
- `NLS_APP_KEY`

So RTI's async-upgrade settings now store those credentials separately.

The Sessions browser now exposes `Upgrade Transcript` for archived sessions
that contain retained audio. The action asks which async transcript provider to
use for that run: Soniox is the default general-purpose choice, and Aliyun is
the Chinese-heavy choice. The current provider adapters are intentionally narrow
script bridges to the same local file-transcription tools used elsewhere on
this Mac:

- Soniox: `/Users/user/Documents/Code/file-transcriber/skills/file-transcriber/scripts/transcribe-soniox.py`
- Aliyun: `/Users/user/Documents/code/archive/aliyun-stt/scripts/aliyun_filetrans.py`

This keeps the RTI feature scoped to archived-session upgrading and avoids
reintroducing the old import/corpus/search architecture. Native REST clients can
replace the script bridges later behind the same `AsyncTranscriptProvider`
protocol.

## Upgrade Transcript Behavior

When RTI runs `Upgrade Transcript`, it:

1. Presents the async provider choices for that run
2. Chooses `audio-mic.m4a` and/or `audio-system.m4a` from the session folder
3. Applies `session.json`'s system-audio offset when merging the two audio legs
4. Runs the provider-specific file transcription adapter
5. Reinserts RTI user notes from the original `transcript.md` by timestamp
6. Saves `transcript.upgraded.md` first
7. Backs up the old `transcript.md` as `transcript.backup-<stamp>.md`
8. Replaces `transcript.md` only after the upgraded artifact succeeds
9. Backs up the old `summary.md` and regenerates it from the upgraded transcript
10. Surfaces progress, errors, provider used, and final status in the Sessions browser

This keeps the live lane fast and the upgrade lane accurate, without conflating
their provider choices.
