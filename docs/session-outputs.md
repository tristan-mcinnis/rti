# Saved-meeting outputs

Date: 2026-10-16. Release checks are recorded in the repository's PLAN.md.

A saved-meeting output turns one already-archived transcript into a short,
purpose-specific document: a client follow-up draft, a decision log, or a
research debrief. It uses the archived transcript, session details and confirmed
speaker names. RTI never retranscribes, never uploads audio, and never rewrites
`transcript.md` or `summary.md`.

This is the "reusable transcript update" half of the Superwhisper comparison;
the live-work priority scheduler is separate.

## What the user sees

In the Sessions window, with an RTI session open, the header's
`doc.badge.plus` glyph toggles the **Saved-meeting output** card above the
reader:

- **Recipe** chips: the three shipped recipes, then any custom instructions the
  user has saved. The shipped recipes are `PromptID`s, so their wording is
  editable in Settings like every other RTI prompt.
- **Provider and destination**, shown before Generate:
  provider, model and destination host, then `<session folder>/outputs/`.
  The route and its credentials freeze at Generate, before background waiting.
- **Generate** (the house ink button) and, while running, **Cancel** plus the
  house thinking dots.
- **Status** in place: "Generating with …", "Saved <file>. Nothing else
  changed.", the error text, or "Cancelled. Any output already completed remains
  available." A status dot
  carries tone, but the words always state the outcome (never colour alone).
- **Custom instructions**: a name field and an instruction editor, saved as a
  custom template. A saved template is selectable and deletable.

Each generated file also appears as a chip in the session's file row, so it
reads in the existing reader and uses the existing Copy, Share, Save Markdown
and PDF export paths. The reader strips the provenance frontmatter, so the user
sees the document body only.

## Where it lives

| Piece | File |
| --- | --- |
| Value types, path rules, rendering, provenance | `RTI/Core/Session/SessionOutputArtifact.swift` |
| Recipes and custom templates | `RTI/Core/Session/SessionOutputRecipe.swift` |
| Unique, atomic, owner-only writer | `RTI/Core/Session/SessionOutputStore.swift` |
| Chooser state reducer | `RTI/Core/Session/SessionOutputFlow.swift` |
| Pure prompt assembly and snapshot | `RTI/Core/Session/SessionOutputPrompt.swift` |
| App-side generator | `RTI/Sources/Session/SessionOutputGenerator.swift` |
| Bounded, non-symlink source reads | `RTI/Sources/Session/SessionOutputSourceReader.swift` |
| Custom-template store | `RTI/Sources/Session/OutputTemplateStore.swift` |
| Chooser view | `RTI/Sources/UI/SessionsControl/SessionOutputsView.swift` |
| Window state and wiring | `RTI/Sources/UI/SessionsControl/SessionsWindowModel.swift`, `SessionsBrowserView.swift` |
| New prompts | `RTI/Core/LLM/PromptID.swift` (`clientFollowUp`, `decisionLog`, `researchDebrief`) |

Storage owners are unchanged. Outputs live under the existing session archive
at `<session>/outputs/`; there is no second database or index. Custom template
text is stored in the same `UserDefaults` config surface as every other RTI
prompt.

## Data and provenance

The artifact is Markdown with a YAML frontmatter block, an H1, then the model
body. The frontmatter records: recipe id, recipe name, and a content hash of
the exact instruction used; the source file, its byte count, and its content
hash; the session folder, id and archived mode; the provider id, display name
and model; the sanitized endpoint; and the generation instant.

The endpoint records only `scheme://host[:port]`; userinfo, path, query and
fragment are removed. API keys never enter an artifact. Generated outputs are
local session artifacts, not part of this source repository.

Everything comes from the archive. The provider and model are frozen at the
start of a run, so provenance names what actually answered.

## Safety rules

- **No overwrite.** A write is `outputs/<recipe>-<stamp>.md`, suffixed `-2`,
  `-3`… when taken. The final step is a hard link, which fails if the
  destination exists; the bytes land in a hidden temp file first and are
  removed on any failure.
- **Owner-only.** The `outputs/` folder is `0700`; each file is `0600`.
- **Contained.** The `outputs/` folder must be a real directory (never a
  symlink) resolving to a direct child of the session folder, and each artifact
  must be a direct, non-hidden, non-symlink child of it. Both the write path
  and the listing path check this before touching bytes.
- **Cancellable.** Cancelling changes the request id, which cancels the view's
  structured `.task`; the store and the generator check cancellation before the
  atomic commit. A cancelled or failed run leaves no partial output and is
  never reported as saved.
- **Text and session details only.** The input is `transcript.md` with frontmatter
  stripped, archived context and confirmed speaker names. Audio is never read.
- **Safe source reads.** An actor opens direct session children with
  `openat`/`O_NOFOLLOW`, rejects linked/non-regular sources, and caps source reads.
  Oversized sources fail explicitly; they are not silently clipped.

## Tests

- `RTI/Tests/SessionOutputRecipeTests.swift` — shipped identity, custom
  templates, catalog merge, id validation and slugs, Codable round-trip.
- `RTI/Tests/SessionOutputStoreTests.swift` — unique atomic owner-only saves,
  provenance round-trip, endpoint sanitization, refusal of empty bodies, unsafe
  ids and occupied paths, symlinked folder and artifact refusal, cancel leaves
  nothing.
- `RTI/Tests/SessionOutputFlowTests.swift` — the deterministic session-switch
  and cancel flows.
- `RTI/Tests/SessionOutputPromptTests.swift` — prompt boundaries, frontmatter
  stripping, label-only speaker substitution without changing quoted words, and
  snapshot context.
- `RTI/RenderTests/SessionsOutputModelTests.swift` — model glue, cancellation,
  session switching, frozen route and credential blocking on an invented vault.
- `RTI/RenderTests/SessionOutputGeneratorTests.swift` — real reader/prompt/writer
  with stub completions; source provenance, identity, linked-source refusal,
  request errors, empty/truncated results and cancellation, without a provider.
- `RTI/RenderTests/SessionOutputRenderProofTests.swift` — dark and light proofs
  of the chooser's ready, generating, saved and failed states and of the card,
  PNG prefix `session-output-`.

All fixtures are invented; no test reads the real vault or a provider.

Release verification: the integrated run executed 777 tests, with 3 expected
skips and zero failures. Strict design lint reported zero hits on the three
touched view/model files. Independent code review accepted the output and
scheduler changes; independent visual QA passed the key light/dark chooser and
generating views. Ten offscreen render proofs were produced. Real-provider
generation and live-window inspection were not performed.

## Known gaps

- The chooser is reached from the header glyph only; there is no menu or
  command-palette entry yet.
- Custom templates are create/delete from the chooser; there is no rename flow
  beyond delete-and-recreate.
