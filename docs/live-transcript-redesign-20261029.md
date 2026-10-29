# Live transcript redesign (2026-10-29)

Problem (Tristan, live meeting screenshot): words split across two speaker
labels, the same line shown as "Speaker N" and "Room speaker N", one header per
short fragment, too much vertical space.

Causes found in code:
- Echo dedupe in `TranscriptPipeline` works per final batch. The two legs cut
  batches at different points, so overlap is partial. The pairwise fallback
  then moves system text into the earlier mic slot, under the mic label. One
  remote sentence alternates between "Speaker 1" and "Room speaker 1".
- Interim text has no echo dedupe at all, so the open line shows twice.
- The projection closes a row on any 1 s pause, and each row draws a header.

Study (static strings only, see notes folder): Ocelli ships `LiveTurnRow`,
`EchoAttribution`, `LiveChannelWindow`, `ConfirmedBox`, `FadingScrollView`:
turns, not fragments; echo attributed to one channel; confirmed versus
tentative text. superwhisper cancels echo at the audio layer (WebRTC AEC3) and
does not show speakers while streaming. Wispr Flow is not installed.

Rules:
1. Echo: the system leg wins. Assemble each leg's tokens into words. A mic run
   (words with gaps under 1 s) is echo when at least half its words match a
   system word (same normalized text) within 1.5 s. Drop the whole run. Applies
   to finals and to interims (against system finals and interims). The old
   batch dedupe stays as a fallback for untimed entries.
2. Merge: consecutive rows of one speaker form one turn with one label line.
   A new turn starts on a speaker change, a note, or a gap over 30 s.
   Rows inside a turn flow inline; paragraph breaks stay as before.
3. Settle: interim words stay in `textTertiary` at the end of their turn and
   recolour in place when final (existing span ink, unchanged).
4. Layout: follows DESIGN.md "Live transcript". One label per run of one
   speaker is now true. No spacing token changes.
5. Scroll: unchanged. The list follows the latest line, pauses when Tristan
   scrolls up, and shows Jump to latest. Turn IDs are the first row's ID, so
   the anchor stays stable while a turn grows.

Tests (XCTest: SWIFT.md keeps rti on XCTest and forbids mixing in a target):
echo run dropped, real overlap kept, interim echo dropped, turn merge, gap
split, a synthetic two-leg fixture renders with no split words and no
duplicate lines.
