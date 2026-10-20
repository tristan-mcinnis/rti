# Personal setup

This is how the author runs RTI on his own Mac. Nothing here is needed to use
RTI. The README covers the public install and the optional integrations in
general terms. This file records the specific wiring, with `~` paths.

## Names

- Repo: `rti`. It builds `RTI.app`, bundle id `com.tristan.rti.personal`, display name RTI.
- The bundle id kept the old "personal" suffix on purpose. macOS ties Microphone, System Audio Recording and Screen Recording grants to the bundle id and the signing identity, so a rename would reset them.
- Two launchd jobs live outside this repo: `com.tristan.rti-crash-watchdog` relaunches RTI after a crash, and `com.tristan.rti-meeting-drain` is a vault tool (below).
- General chat and the Chief of Staff live in Quick Launch's AI Chat. RTI and Quick Launch share `HouseChatCore` code, not histories, settings or keys.

## Config file

`~/.config/rti/config.json` anchors every vault path (`VaultPaths.swift` reads it; set `RTI_CONFIG_HOME` to point tests elsewhere). The live values:

```json
{
  "recordings_dir": "~/Documents/Work/Inner-Chapter/meetings/recordings",
  "transcripts_dir": "~/Documents/Work/Inner-Chapter/meetings/transcripts-raw",
  "sessions_dir": "~/Documents/Work/Inner-Chapter/meetings/sessions",
  "auto_process": true,
  "auto_process_scoped_tools": true,
  "local_vision": {
    "enabled": true,
    "endpoint": "http://127.0.0.1:8078",
    "model": "qwen3-vl",
    "max_tokens": 400,
    "timeout_seconds": 45,
    "save_frames": true,
    "ambient_describe": false
  }
}
```

The file also carries `auto_process_prompt`, a custom prompt for the unattended `/meeting` run. `auto_process` (default false) turns that run on; `auto_process_scoped_tools` (default false) adds the fixed `--allowedTools` list; the run always uses `--permission-mode acceptEdits` and never skips permissions. Optional keys: `soniox_file_script` moves the transcript-upgrade script. The local vision lane talks to the local-models daemon.

## Where everything goes

**1. The session archive**, one folder per session:

```
~/Documents/Work/Inner-Chapter/meetings/sessions/<yyyy-MM-dd HHmmss>/   # sessions_dir in the config
  transcript.md         # live transcript, YAML frontmatter, inline notes
  chat.md               # assistant chat log (only if you chatted)
  screen-context.md     # screen trail: OCR, vision summaries, frame refs (only if any)
  frames/               # compressed JPEG frames per capture
  notes.md              # generated live notes (only if enabled and produced)
  title.txt             # session title (only if you renamed it)
  session.json          # metadata: mode, workstream, duration, audio file names
  speaker-names.json    # live speaker renames (only if you renamed)
  audio-mic.wav         # mic leg, kept for the transcript upgrade
  audio-system.wav      # system-audio leg
```

Every `.md` file carries YAML frontmatter (`title`, `type: reference`, `date`, `source: rti`, `workstream:` when a project was picked in Setup, `projects: [rti]`, `tags: [rti]`) so downstream tools can title and link it. Structured chat threads live under `the RTI owner folder under `chats/threads/``. Their source and request blobs live in `~/Library/Application Support/RTI/chat-assets/`.

**2. The canonical meeting lane.** On finish, and again after the automatic transcript upgrade, RTI exports plain text into the raw-transcript lane:

```
~/Documents/Work/Inner-Chapter/meetings/transcripts-raw/
  rti-session-<yyyyMMdd-HHmmss>-transcript.txt    # canonical raw transcript (plain text)
  rti-session-<yyyyMMdd-HHmmss>-rti.md            # sidecar: notes, screen context and chat (source: rti-live)
```

**3. Meeting processing** happens in the `/meeting` skill, never in the app:

- The `com.tristan.rti-meeting-drain` LaunchAgent runs every 30 minutes. It finds unprocessed `-transcript.txt` files and runs `/meeting` headless. That writes the canonical meeting note in the project's `07-fieldwork/transcripts/meeting/` (or the meetings inbox, unrouted) as `YYYYMMDD-<type>-<topic>.md`, folds the `-rti.md` sidecar in as priority signal, and writes a speaker-resolved `-transcript.named.txt` sibling. The raw transcript is never edited.
- RTI also fires the same `/meeting` run itself through `claude -p`. This Mac sets `auto_process` and `auto_process_scoped_tools` to true. Both default to false for everyone else. The run uses `--permission-mode acceptEdits` plus a fixed `--allowedTools` list; RTI never passes `--dangerously-skip-permissions`.
- The assistant's `search_vault` tool is a local keyword scan of the notes folder. There is no search index.

Legacy files you may still see: `meetings/recordings/rti-<UUID>-mic.m4a` (old builds kept audio there) and `*.meeting.json` sidecars from Meeting Sentinel. The Sessions browser still lists them as recorded meetings.

## Transcript upgrade

The upgrade script is `~/Documents/code/file-transcriber/skills/file-transcriber/scripts/transcribe-soniox.py`. RTI calls it with English and Chinese hints and uses the one Soniox key for both lanes. The Aliyun option was removed on 2026-09-26.

## Installing on this Mac

`scripts/install-local.sh` builds Release, re-signs the app with the Apple Development certificate, and replaces `/Applications/RTI.app`.

- The signing identity comes from `RTI_SIGN_IDENTITY` in the environment, or from the gitignored `.release.env`, or from the first Apple Development identity in the login keychain.
- Why a stable identity: an ad hoc signature changes on every build and resets every permission grant. A certificate keeps the designated requirement the same, so the grants survive.
- The script refuses a dirty tree, because the build compiles the working tree. It stamps the pinned `HouseChatCore` and `HouseDesign` versions and revisions (from the committed `Package.resolved`) into the bundle.
- It will not quit RTI while a recording is running or paused. It asks the running app for its status over the control socket first.
- `scripts/sign-install.sh` is the older route with a self-signed identity. Prefer `install-local.sh`.

## Tests on this Mac

Run the tests, including the keyword-search tests, with:

```bash
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug \
  -derivedDataPath .deriveddata test -only-testing:RTITests/VaultSearchTests
```

Render proofs use an invented fixture vault, never the real one.
