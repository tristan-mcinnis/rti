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
  "recordings_dir": "~/vault/kb/databases/meetings/recordings",
  "transcripts_dir": "~/vault/kb/databases/meetings/transcripts-raw",
  "auto_process": true,
  "auto_process_yolo": true,
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

The file also carries `auto_process_prompt`, a custom prompt for the unattended `/meeting` run. `auto_process` (default false) turns that run on; `auto_process_yolo` (default false) adds `--dangerously-skip-permissions`, and without it the run uses `--permission-mode acceptEdits`. Optional keys: `soniox_file_script` moves the transcript-upgrade script. The local vision lane talks to the local-models daemon.

## Where everything goes

**1. The session archive**, one folder per session:

```
~/vault/kb/databases/projects/personal/rti/sessions/<yyyy-MM-dd HHmmss>/
  transcript.md         # live transcript, YAML frontmatter, inline notes
  chat.md               # assistant chat log (only if you chatted)
  notes.md              # generated live notes (only if enabled and produced)
  discussion-guide.md   # guide coverage (only if a guide was loaded)
  live-intelligence.md  # tagged findings (only if any)
  screen-context.md     # screen trail: OCR, vision summaries, frame refs (only if any)
  frames/               # compressed JPEG frames per capture
  summary.md            # end-of-session summary (and title.txt for the browser)
  session.json          # metadata: mode, workstream, duration, audio file names
  speaker-names.json    # live speaker renames (only if you renamed)
  audio-mic.wav         # mic leg, kept for the transcript upgrade
  audio-system.wav      # system-audio leg
```

Every `.md` file carries YAML frontmatter (`title`, `type: reference`, `date`, `source: rti`, `workstream:` when a project was picked in Setup, `projects: [rti]`, `tags: [rti]`) so the vault's Neon ingester titles and links it. Structured chat threads live under `~/vault/kb/databases/projects/personal/rti/chats/threads/`. Their source and request blobs live in `~/Library/Application Support/RTI/chat-assets/`.

**2. The canonical meeting lane.** On finish, and again after the automatic transcript upgrade, RTI exports plain text into the raw-transcript lane:

```
~/vault/kb/databases/meetings/transcripts-raw/
  rti-session-<yyyyMMdd-HHmmss>-transcript.txt    # canonical raw transcript (plain text)
  rti-session-<yyyyMMdd-HHmmss>-rti.md            # sidecar: summary, notes, findings, chat (source: rti-live)
```

**3. Vault ingestion** happens vault-side, never in the app:

- On session stop RTI starts `~/vault/.claude/tools/triage/route-rti-session.py` and does not wait for it. With a workstream declared, it files a field-notes companion in that project. Otherwise the session stays in `rti/sessions/`.
- The `com.tristan.rti-meeting-drain` LaunchAgent runs every 30 minutes. It finds unprocessed `-transcript.txt` files and runs `/meeting` headless. That writes the canonical meeting note at `~/vault/kb/databases/meetings/YYYYMMDD-<type>-<topic>.md`, folds the `-rti.md` sidecar in as priority signal, and writes a speaker-resolved `-transcript.named.txt` sibling. The raw transcript is never edited.
- RTI also fires the same `/meeting` run itself through `claude -p`. This Mac sets `auto_process` and `auto_process_yolo` to true. Both default to false for everyone else.
- The Neon/Hermes ingest watcher indexes the archive's Markdown for search. The assistant reaches it through the `search_vault` tool, which uses `bun` and the vault's search CLI.

Legacy files you may still see: `meetings/recordings/rti-<UUID>-mic.m4a` (old builds kept audio there) and `*.meeting.json` sidecars from Meeting Sentinel. The Sessions browser still lists them as recorded meetings.

## Transcript upgrade

The upgrade script is `~/Documents/code/file-transcriber/skills/file-transcriber/scripts/transcribe-soniox.py`. RTI calls it with English and Chinese hints and uses the one Soniox key for both lanes. The Aliyun option was removed on 2026-09-26.

## Installing on this Mac

`scripts/install-local.sh` builds Release, re-signs the app with the Apple Development certificate, and replaces `/Applications/RTI.app`.

- The signing identity comes from `RTI_SIGN_IDENTITY` in the environment, or from the gitignored `.release.env`, or from the first Apple Development identity in the login keychain.
- Why a stable identity: an ad hoc signature changes on every build and resets every permission grant. A certificate keeps the designated requirement the same, so the grants survive.
- The script refuses a dirty tree, because the build compiles the working tree. It also refuses if the shared `HouseChatCore` sources in the sibling Quick Launch checkout have uncommitted edits. It stamps the commit and the `HouseChatCore` source hash into the bundle.
- It will not quit RTI while a recording is running or paused. It asks the running app for its status over the control socket first.
- `scripts/sign-install.sh` is the older route with a self-signed identity. Prefer `install-local.sh`.

## Tests on this Mac

The public README runs the tests without the vault. Here, also run the live tests when you touch vault search:

```bash
TEST_RUNNER_RTI_LIVE_VAULT=1 xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug \
  -derivedDataPath .deriveddata test -only-testing:RTITests/VaultSearchCLITests
```

CI never sets that variable. Render proofs use an invented fixture vault, never the real one.
