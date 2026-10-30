# RTI workflow contracts

Working brief: follow each user goal through entry, action, result, navigation away, and recovery. At each boundary identify saved state, unsaved work, pending context, and running work. Reproduce failures with invented data, then verify the repaired transition through the real UI path.

| Transition | Preserve | Reset or stop | Verification |
| --- | --- | --- | --- |
| Live to another page and back | Draft, attachments, chat and recording | Hidden transcript presentation | Workspace visibility and composer regressions |
| Explicit new chat or conversation hand-off | Saved records and recording | Previous draft, pending attachments, mentions and queued follow-up | Composer boundary regressions |
| New chat while a resume or save is pending | The newer conversation, draft and stream | Obsolete async completions | Deterministic composer race regressions |
| Failed explicit mode save | Edits and last confirmed stored mode | Saved/clean status until persistence succeeds | Injected-writer failure and retry |
| Failed send in the same chat | Draft and its pending context | Failed request state only | Chat runtime regressions |
| Leave and return to Settings | Unsaved form edits and selection | No automatic credential save | Settings draft regressions and UI walkthrough |
| Return to Chats | Search and selected record | Stale list/detail snapshots | Store-backed freshness regressions |
| Close, hide or minimise the window | Capture, saved records and drafts | Playback and hidden transcript presentation | Visibility regressions and installed-app walkthrough |

The House visual components remain the interface vocabulary. These contracts govern what those components do together. A passing render proves layout; state-transition checks prove that work lands in the right conversation and survives navigation.

Verification: 82 integrated workflow/chat checks passed, including 22 new regressions. A separate read-only reviewer identified stale asynchronous completions and false save success; those findings were fixed and re-reviewed before release. Provider and mode failures use injected test writers; composer tests use temporary stores and fake provider streams.
