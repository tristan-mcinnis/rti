# 0003: Shared chat logic, separate histories, retained submitted sources

Date: 2026-09-17
Status: Accepted design; release verification is recorded in the implementation evidence.

## Decision

RTI consumes the local Swift package at
`../../quick-launch/Packages/HouseChatCore` relative to `RTI/project.yml`.
It shares context policy, command parsing, versioned records, asset archives,
document extraction and lexical source selection with Quick Launch. Its
macOS 14 floor remains unchanged. This dependency shares code, not credentials,
defaults, processes or conversation ownership.

RTI's structured conversation owner is the existing vault project's
`chats/threads/` directory. Original submitted documents, screenshots, images,
selections, fetched bodies, extraction results and credential-free request
snapshots belong in local `Application Support/RTI/chat-assets/`. Threads refer
to those immutable, content-addressed blobs. Meeting audio and frame archives
keep their existing owners. Compatibility daily logs and meeting chat exports
link back to thread and turn IDs; they do not establish another canonical chat.

Save submitted sources before sending to a provider. A persistence failure
blocks Send and keeps the draft. Retain submitted content until explicit
removal. Do not prune by age or count. A missing or corrupt archive is not an
empty archive. Retain rollback data during migration and do not silently fetch
an unavailable legacy source again.

Attachment deletion is reference-aware and conservative. An unreadable owner
blocks cleanup; uncertainty must retain bytes, never erase the last copy.
Deletion of a chat must not remove original documents or linked recordings.
Keep assets owner-only and out of Git and automatic vault ingestion. No new
cloud sync is part of this change; ordinary local backup eligibility remains.

Freeze the chosen and effective provider, model, reasoning and image route per
turn. A settings change must not alter an in-flight request or relabel an old
answer. Cloud screenshot inference is permitted, with a visible destination
before Send and on the saved answer. Missing capabilities or credentials block
Send instead of silently changing providers.

Questions about current or retained sources default to those sources. The same
policy gates pre-search, tool offering and tool execution. Broader evidence
requires explicit intent or a visible override. Lexical document selection
stays local, bounded and location-labelled, with honest no-match and partial
coverage notices. It is not an embedding index or a workbook calculation engine.

`/new` and `/clear` start clean chat context without erasing saved history or
stopping recording. Unknown slash commands stay local until the user explicitly
chooses Send as Text. RTI keeps its configured empty-Return action.

## Why

The prior apps differed in retrieval defaults, model routing and attachment
lifetime. Users could not reliably tell what a response used or resume the same
source after a restart. One implementation removes that drift while preserving
each app's distinct ownership and interaction model.

## Non-goals

No combined RTI/Quick Launch history, credential-store migration, new daemon,
vector database, background crawl, expanded capture or autonomous file editing.

## Acceptance references

- `../../../quick-launch/docs/chat-harmonization-plan-20260917.md`
- `../../../quick-launch/docs/chat-harmonization-verification-20260917.md`
- Shared package `README.md` and executable tests

The design decision does not substitute for current-source tests, migration
checks, independent review or verification of the installed app.
