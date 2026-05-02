# RTI

Real Time Intelligence — a macOS overlay that listens to a meeting, transcribes both sides, and answers questions about what's been said. This file is the project glossary. Add terms as they're resolved during architecture conversations.

## Language

**Session**:
A single recording-and-conversation lifecycle, from the moment the user starts listening to the moment they stop. Owns the audio capture, the transcript, and any chat the user had with the LLM about that audio.
_Avoid_: meeting, recording, conversation, run.

**Word**:
A single token emitted by Soniox's transcription stream, carrying timing, speaker id, confidence, and an `is_final` flag. The atomic unit before grouping.
_Avoid_: token, fragment.

**Speaker Turn**:
A contiguous stretch of Words attributed to one speaker, collapsed into a single block. Created by walking the Word stream and starting a new turn whenever the speaker id changes. Distinct from a Word (always one token) and from a Transcript Entry (the persisted form).
_Avoid_: run, utterance, segment, group, block.

**Transcript Entry**:
A persisted Speaker Turn — one row in `transcript_entries`, the durable form the rest of the app reads from. A Speaker Turn is the runtime aggregate; a Transcript Entry is what survives a restart.
_Avoid_: transcript line, transcript row, segment row.

**Transcript Context**:
The plain-text rendering of a Session's Transcript Entries that gets fed to the LLM as part of a prompt. Distinct from the transcript shown in the UI: it uses raw speaker IDs (`self`, `them_1`, `note`) rather than display names, and tags user-typed notes with `[user note]:` so the model can distinguish them from spoken turns. May cover the full session or a recent-time window.
_Avoid_: transcript text, prompt context, LLM context.

**Corpus**:
The user's permanent, queryable record of every Session, stored as plain markdown files in `~/meetings/` (configurable). The Corpus is canonical — SQLite is a derived index over it. If RTI is uninstalled, the Corpus survives and remains `grep`-able forever. External agents (Claude Code, Codex, Gemini CLI) read the Corpus directly via filesystem or via RTI's MCP server.
_Avoid_: archive, exports, vault, history.

## Relationships

- A **Session** has many **Transcript Entries**.
- A **Transcript Entry** is the persisted form of one **Speaker Turn**.
- A **Speaker Turn** is built from one or more contiguous **Words** with the same speaker id.
- A **Transcript Context** is rendered from a Session's **Transcript Entries** for the LLM to read.

## Flagged ambiguities

- "Run" was used in code (`Run` struct, `groupByRuns`) to mean **Speaker Turn**. Resolved: rename to `SpeakerTurn` when the duplicated grouping logic is consolidated.
