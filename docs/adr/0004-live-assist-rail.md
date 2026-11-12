# 0004: Live help in a rail beside the transcript

Date: 2026-11-12
Status: Accepted. Built in Bands 1 and 2 (commit `fd042d6b`).

## Context

Auto cards had their own tab. To read a card, the user left the
transcript, and the unread dot pulled the eye during the call. Auto was
also opt-in, so most calls had none. On a research call the guide gaps
and the codebook topics were on other tabs too.

## Decision

Live help sits in one rail beside the Transcript on the Live page
(`LiveAssistRail`). In a narrow window the rail folds to a one-line
strip (`LiveRailStrip`, below 752 pt of panel width). The Auto tab and
its unread dot are gone. The old Auto shortcut slot opens Transcript, so
the other tab digits do not move.

Auto runs by call type. It is on by default for client and research
calls and never runs on internal or personal calls. On client and
research calls a toggle the user set wins
(`AutoAssistSettings.isActive(for:)`). `AutoAssistPrompt` frames
each pass for the call type: a client pass steers toward the brief's
goal, and a research pass works from the guide's gaps and the current
question and never sees the brief.

The rail on a research call also shows the guide gaps (`GuideGaps`) and
the codebook topics (`topicMap`).

## The quiet rules

The rail must not pull attention from the call.

- At most one new card per 60 s (`LiveRailPacer.spacing`).
- On a client call, a new card waits 4 s after the user's own speech.
- At most 3 cards in the "now" lane and 2 in the "threads" lane.
- An unpinned card fades to "Earlier" 4 min after it shows.
- A dismissed card never comes back.
- Automatic Auto passes run at most once per 60 s on client and research
  calls (`AutoPassState.floor(for:)`). Only "Suggest now" skips that
  floor.

The pacing rules are pure values (`AutoPassState`, `LiveRailPacer`,
`LiveRailBoard`) with unit tests. `docs/state-machines.md` lists them.

## Charter boundary

RTI captures and assists live. The rail follows that rule:

- Rail items, card states and guide gaps live in memory only. A new
  session resets them.
- The rail archives nothing. The session archive is unchanged.
- The rail does no analysis after the call. Analysis stays downstream in
  the `/meeting` skill and Pi.
- The rail adds no RTI database and no index. Auto's project search is
  the same local keyword scan as `search_vault`, kept inside the
  project.

## Consequences

- The transcript stays on screen while help shows, so the user does not
  switch tabs during a call.
- More calls run Auto, so background LLM cost goes up. The 60 s floor
  bounds it to about 60 passes an hour.
- Cards that the pacer holds back may fade unseen. A later pass may
  offer them again.
