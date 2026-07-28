# ADR 0002: Vault Retrieval as Assistant Context

**Date**: 2026-07-12
**Status**: Accepted
**Author**: RTI engineering

## Context

RTI's personal refocus removed the old in-app corpus: no database, no session
history reader, no cross-session search UI, and no post-hoc Q&A surface. That
constraint still stands.

The current assistant can also use selected project/client context and search
the local vault when a live meeting question needs prior knowledge. That is
useful, but it can look like the old corpus coming back unless the seam is
named and constrained.

## Decision

RTI may perform vault retrieval only as **assistant context** for a live or
standalone assistant turn. Retrieval is not an in-app corpus product.

Allowed:

- The assistant may search the vault to answer a user question.
- The assistant may focus retrieval on the selected project/client.
- The assistant may expose source paths in the chat trace or answer.
- The implementation may use a structured `VaultRetrieval` module with
  production adapters such as the vault/Neon CLI and local markdown search.

Not allowed:

- An in-app vault browser.
- A cross-session search UI.
- A persistent RTI-owned search index or database.
- A post-hoc corpus Q&A surface separate from the assistant turn.

## Consequences

`VaultRetrieval` is the seam for prior-knowledge lookup. Callers should receive
structured source metadata and model-facing text from that module instead of
parsing formatted search output.

Future architecture reviews should not flag vault retrieval itself as a
violation. They should flag any UI, persistence, indexing, or reader feature
that turns retrieval into the old corpus surface.
