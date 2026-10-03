# RTI Production Readiness Benchmarks

Scope: UK-based personal RTI use cases: live client/research calls, fast vault-assisted recall, in-call note capture, source-grounded answers, and post-call text handoff. This excludes security hardening by design.

## Readiness Verdict

RTI is **private-beta / pilot ready**, not yet production-grade.

It is ready for controlled use by the owner on real UK calls where occasional rough edges are acceptable. It should not be called production-grade until the latency, meeting stability, source grounding, and UX regression gates below are run consistently and pass on the target Mac.

## Target User Workflows

1. Join a live Zoom/Teams/Meet call and start RTI without disrupting the meeting.
2. See live transcript turns from self and other speakers quickly enough to support the conversation.
3. Ask the assistant a question and receive visible progress immediately, then a grounded answer.
4. Use `/answer`, `/search`, `/sources`, `/new`, and `@file` without reading docs.
5. Use RAG vault-wide by default, and project/client-scoped when selected.
6. Inspect sources without losing screen real estate.
7. Capture quick notes and return to chat without layout jumps.
8. Stop the session and get text artifacts without retaining audio unexpectedly.

## Benchmarks

| Area | Production-grade target | Pilot-acceptable target | Current status |
| --- | --- | --- | --- |
| Idle overhead | 0-1% CPU, no wake-loop, stable memory | 0-2% CPU | Passing in spot checks: RTI sampled at 0% idle CPU |
| Overlay open/focus | Input focused within 100 ms | Within 250 ms | Implemented; needs UI automation coverage |
| Composer typing | No visible dropped frames while typing | No sustained lag | Improved: `@` suggestions moved off render path |
| `@` file picker first result | P95 under 100 ms after warm index | P95 under 250 ms | Improved with background prewarm + cache; needs repeated measurement |
| `@` fuzzy recall | Multi-token and abbreviation search, e.g. `@wear dg` | Filename/path fuzzy search | Implemented for path tokens + acronyms |
| Slash commands | Arrow navigation consistent with layout; command executes predictably | Same | Implemented left/right for horizontal `/` bar |
| RAG answer start | Visible progress within 150 ms | Within 300 ms | Implemented progress rows; needs automated UI check |
| RAG source transparency | Every vault-grounded answer exposes source files and search timing on demand | Source popover available | Implemented source popover |
| Vault search latency | P95 local/hybrid retrieval under 2 s for common project queries | Under 5 s | Needs benchmark harness over representative vault queries |
| Live transcript latency | Interim words visible under 1.5 s, final turns under 3 s | Under 5 s | Needs real-call/provider measurement |
| Audio stability | Starting RTI before/after call never crashes Zoom/Teams/Meet | Manual pass on target setup | Needs manual regression gate |
| Speaker usefulness | Labels remain understandable for self/remote/multiple participants | Usable but not diarization-perfect | Improved labels; needs real-call validation |
| UI stability | No layout jumps switching chat/note/source states | No major jumps | Mostly addressed; needs screenshot regression |
| Failure clarity | Search/LLM/audio failures show durable status and recovery path | Basic status visible | Partially implemented |

## Functional Gates

These are the checks required before calling a build production-ready.

1. **Cold start**
   - Launch RTI.
   - Open overlay.
   - Cursor is focused in the composer.
   - Idle CPU remains at or below 1% after 30 seconds.

2. **Fast local interactions**
   - Type `/`, navigate with left/right, press Enter.
   - Type `@wear dg`; suggestions appear without typing lag.
   - Select a suggestion; it inserts an exact quoted vault path.
   - Type `/new`; chat clears.

3. **Vault/RAG behavior**
   - With no project selected, ask a vault question; it searches the whole vault.
   - Select a project; ask the same style of question; sources should skew to that project.
   - Open source popover; source paths and search timing are visible on demand, not inline.

4. **Live meeting behavior**
   - Join Zoom/Teams/Meet, then start RTI.
   - Start RTI before joining the call, then join; meeting must not crash or lose audio.
   - Both self and remote audio transcribe.
   - `/answer` responds to the latest client question.

5. **Responsiveness under use**
   - During a streaming answer, the composer remains responsive.
   - Stop button reacts immediately.
   - Opening sources, notes, and transcript does not freeze the overlay.

## Automated Gates To Keep

Run before every installed build:

```bash
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build -quiet
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI \
  -only-testing:RTITests/VaultFilesTests \
  -only-testing:RTITests/VaultSearchTests \
  -only-testing:RTITests/VaultWorkstreamMatchTests \
  -only-testing:RTITests/AssistantActionTests \
  test -quiet
```

## Hardening Plan

1. **Instrument latency**
   - Add local signposts or structured RTI logs for overlay open, first keystroke, `@` suggestion returned, tool call started, first LLM token, and answer complete.
   - Report p50/p95 in a small diagnostics view or log summary.

2. **Build a representative vault benchmark**
   - 20 UK/client-style queries across project status, transcripts, discussion guides, evidence decks, and recent sessions.
   - Track retrieval latency and source quality.
   - Current seed set lives in `docs/rag-benchmarks.md`.

3. **Add UI automation**
   - Launch app, focus overlay, type `/`, type `@wear dg`, verify no layout jump and suggestion insertion.
   - Capture screenshots for compact and tall panel sizes.

4. **Add meeting regression script**
   - Manual checklist for Zoom, Teams, and Meet on the target Mac/audio setup.
   - Record start-before-call and start-after-call results.

5. **Tighten assistant reliability**
   - Ensure every RAG answer has source metadata available.
   - Add graceful fallback text when retrieval misses or provider latency is high.
   - Completed baseline: turn logs now include `{latency, sources}` for completed assistant turns.

6. **Tune performance budget**
   - Keep idle CPU at 0-1%.
   - Keep `@` suggestion p95 under 100 ms warm.
   - Keep local vault retrieval p95 under 2 s or show progress immediately and degrade gracefully.
