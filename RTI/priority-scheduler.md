# Live-work priority (LLM admission)

RTI lets interactive chat turns and deferred jobs (end-of-session
summary, generated session title, live analysis ticks, saved-meeting output
recipes) run on the same provider client. This document is the contract for how
those requests are ordered.

## The seam

One small actor, `LLMAdmissionController` (`RTI/Core/LLM/LLMAdmission.swift`),
plus a priority on each request:

- `LLMPriority.foreground` — the user is waiting (the live chat turn, the
  callback `stream()` path, a foreground `collect*`).
- `LLMPriority.background` — deferred work (summary, title, analysis tick,
  output recipe).

`LLMRequest` carries the priority and consults the shared controller:

- The tool-aware interactive turn (`streamWithTools`) is foreground by
  construction: `ToolLoop.run` holds **one foreground permit for the whole
  multi-round turn**, so a background request cannot start between rounds.
- `collectAsync` / `collectDetailedAsync` honor the request's priority
  (background callers pass `LLMRequest(priority: .background)`).
- The callback `stream()` path always holds foreground admission for the life
  of its stream. It is interactive because emitted deltas cannot be replayed.

Existing collect signatures stay unchanged. Deferred callers opt in with
`LLMRequest(priority: .background).collectDetailedAsync(...)`.

## The policy (what is actually guaranteed)

- **Foreground never waits.** `acquireForeground()` is not suspending. A live
  request is admitted the instant it arrives.
- **Background waits for foreground to settle.** `acquireBackground()` returns
  only while no foreground lease is live; a queued background caller suspends
  and is woken when the last foreground lease is released. If foreground is
  still live it re-suspends.
- **Background yields to foreground.** An in-flight background collect races a
  foreground-arrival signal; when foreground arrives the provider read is
  cancelled (a yield, not an error) and the request re-queues, resuming once
  foreground settles.
- **Bounded retries.** A background request yields at most
  `LLMRequest.backgroundPreemptionAttempts` (6) times, then reports failure
  rather than spinning in an endless requeue.
- **Idempotent release.** Foreground slots are tracked by lease id, so releasing
  the same lease twice is a no-op and can never free another request's slot.
- **Cancellation-safe.** A queued background waiter woken by cancellation
  resumes immediately, removes its waiter, and leaves the scheduler serving new
  foreground and background work. Collect cancellation is forwarded to the
  provider read and returns nil promptly.

The atomic background admission (`LLMBackgroundAdmission`) captures the lease
and the foreground epoch in one actor call, so a foreground arrival cannot slip
between "no foreground" and "which epoch to watch".

## Not claimed

There is no transport-level preemption. A provider stream already on the wire is
not paused; the background request is **cancelled and re-queued**. Background
work is deferred and retried, not scheduled ahead of foreground at the network
layer. A cancelled provider may still bill for work already performed. After six
yields the caller receives failure and may retry; this is not a durable job queue
or a hard real-time scheduler.

## Tests

- `RTI/Tests/LLMAdmissionTests.swift` — the pure policy: foreground never waits,
  background waits/resumes, duplicate release is a no-op, foreground-arrival
  signals fire, cancelled waiters leave the scheduler healthy.
- `RTI/RenderTests/LLMRequestPriorityTests.swift` — `LLMRequest` integration:
  background waits for held foreground, yields mid-flight and retries exactly
  once, foreground does not wait behind in-flight background, cancellation stops
  an in-flight collect and does not wedge the scheduler, single-flight cancels a
  superseded collect, frozen routes across retries, the six-preemption bound,
  complete multi-round tool leases (including mid-tool cancellation), and
  `stream()` acquiring and releasing a slot.

Both suites are deterministic (no `Task.sleep`; a background acquisition cannot
succeed while a foreground lease is live, so the "not yet acquired" assertions
are exact).
