# RTI from first principles (2026-11-14)

Status: proposal and audit. Items marked **done** shipped in the 2026-11-14 calm pass; the rest needs Tristan's yes.

## The job, in one line

Capture the call, keep the researcher oriented in the guide, and help in the moment. Everything else is downstream.

## What was measured (live, during a 75-minute research group)

| Moment | Main thread | Cause | Status |
|---|---|---|---|
| Idle while recording | 7% busy | transcript updates, menu clock | fine |
| Open Prepare | ~200 ms stall | EventKit read on the main actor, every visit | **done**: read at most once a minute |
| Open Prepare | small stall | vault project walk on the main actor | **done**: off the main actor |
| Switch to Notes | ~170-300 ms | every Markdown block laid out on each visit | **done**: lazy list again, bottom anchor |
| Any view switch | ~200 ms | SwiftUI re-measures deep stacks; Markdown views rebuilt | next: pre-render Markdown off main |
| First open of Sessions | ~15 s "Loading sessions…" | each session folder read on open | next: needs a decision (below) |
| Accessibility clicks | some refused | main thread busy past the AX timeout | follows from the rows above |

## If RTI were built backend-first

1. **One journal per session, everything else a projection.** Audio legs, transcript finals, notes, markers, cards and guide positions append to one session journal on disk. Views read projections of it. Today about a dozen `@Observable` singletons each keep their own slice and reset 5 to 15 fields by hand.
2. **The main thread only draws.** File reads, EventKit, vault walks, Markdown parsing, prompt assembly and JSON decode run off the main actor. A view never does I/O in `onAppear`.
3. **Markdown is rendered once.** Each answer or note block becomes an `AttributedString` off the main actor when it lands, cached by id. Views draw plain `Text`, not a Markdown view tree per block.
4. **One research pass, not four.** Guide, codebook, Auto and notes each call the model on their own tick (about 150 calls an hour). One structured pass every two minutes could return all four (about 30 an hour): cheaper, more consistent, and one place to debug.
5. **States are enums.** Every lifecycle is one enum with its events listed (`docs/state-machines.md`). No pairs of Bools that must agree.
6. **A session list that opens instantly.** A derived listing file per sessions folder (title, date, duration, call type), rebuilt from the folders and safe to delete. This touches the "no RTI database or index" rule, so it needs a yes. It is a listing, not a search index.

## Settings: what a user should see

| Show (changes how a call goes) | Hide (sensible default, file or palette only) |
|---|---|
| Assistant provider and key | Notes interval, Auto pass floors, rail pacing |
| Default call type | Echo cancellation (off; it breaks the mic) |
| Screenshots on or off by default | Soniox reconnect timings, chat history caps |
| Text size | Contrast (full ink is the default now) |
| Prompts (advanced, one page) | Research window minutes per action (whole call is right) |
| Sessions folder | Pinyin on/off (keep, but under Advanced) |

## The layout, as it should read

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ●●●  ☰  SH Young Skincare Users · Research      🎙▾  👁   ⏸  ● 1:16 Finish │
├────────────┬──────────────────────────────────────────┬───────────────────┤
│ Prepare    │ Them 1:15:02                             │ NOW ASKING        │
│ Assist     │ 我觉得它会好一些。嗯，怎么说？            │ S3Q11 Cica serum  │
│▸Transcript │                                          │ Would you choose… │
│ Guide      │ Them 1:15:20                             │                   │
│ Notes      │ 可能也它的那个广告做得太好了。            │ GO BACK TO        │
│ Codebook   │                                          │ S2Q1 Face concerns│
│ ────────── │                                          │ Thin: 1 quote     │
│ Sessions   │                                          │                   │
│ Chats      │                                          │ TO ASK            │
│ Settings   │                                          │ 您提到…小样？      │
│            │                                          │ nín tí dào…       │
│            │                                          │ Where do samples… │
│            │                              ↓ Latest    │ ⧉  📌  ✕          │
├────────────┴──────────────────────────────────────────┴───────────────────┤
│ (+)  Ask about this meeting…                        Quick recap ⌘↩   (⌘)  │
└───────────────────────────────────────────────────────────────────────────┘
```

Below 1000 pt, and on Sessions, Chats and Settings, the sidebar is icons only (**done**).

## Implicit state machines found

| # | What | Risk | Status |
|---|---|---|---|
| 1 | Queued follow-up fired on any end of a turn: Esc, an error or a screen-policy cancel sent it | user-visible bug | **done**: sent only when the answer finished (`lastTurnCompleted`) |
| 2 | Chat error triple `lastError` / `lastErrorIsAuth` / `lastErrorTurnID`: some writes leave stale halves (wrong "Open Settings", Retry under the wrong turn) | user-visible | next: `ChatIssue` enum |
| 3 | Session `lastError` shared by transcription, markers and archive: one overwrites another, auth flag sticks | user-visible | next: keyed `SessionIssue` set |
| 4 | LLM turn phase spread over 9 fields, reset in 5 places | DX | next: `TurnPhase` enum |
| 5 | Stimulus "Order confirmed" lived in the view; a cancelled load hid the spinner | small bug | **done** |
| 6 | Session id outlives the run; `isRunning && id == x` in 15 files | DX | next: run on each phase case |
| 7 | Composer palette and add-context as two Bools kept exclusive by hand | DX | next: one `pane` value |
| 8 | Auto `railStopped` beside `AutoPassState`: an explicit pass after Stop still runs | small cost | next: `stopped` phase |
| 9 | Codebook `error`/`notice` with ten writers | DX | next |
| 10 | Audio link flags (parked / armed / connected) | DX, guarded | leave; covered by tests |

## Agent experience

- **Done:** hidden views leave the accessibility tree (the Transcript toolbar showed on every view), and sidebar rows carry stable ids (`workspace.sidebar.<View>`, `workspace.route.<Page>`).
- **Next:** the control socket answers start, stop, pause, resume, sessions and status. Add `view <name>` and a `state` reply (page, view, guide position, recording phase) so an agent can navigate without clicking. This changes the house command contract (`design-system/docs/app-commands.md`), so it needs a yes.
