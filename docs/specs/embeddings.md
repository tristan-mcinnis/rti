# Embeddings retrieval (Ask Your Corpus v2)

**Status:** v1 shipped 2026-05-12 using Apple's built-in `NLEmbedding`. v2 (bge-small via MLX) is the upgrade path below.

## v1 — what shipped

Pragmatic minimum: zero new deps, zero install friction, real concept-bridging.

- `RTI/Sources/Corpus/Embedder.swift` — wraps `NLEmbedding.sentenceEmbedding(for: .english)`. 512-dim, L2-normalised Float32 vectors.
- `RTI/Sources/Corpus/ChunkPolicy.swift` — paragraph-greedy chunks, ~500 words with 60-word overlap.
- `RTI/Sources/Corpus/CorpusIndexer.swift` — embeds summary + transcript chunks per session, writes to `corpus_embeddings`. Mirrors every call site of `CorpusFTSReindexer.reindex`.
- `RTI/Sources/Corpus/HybridRetriever.swift` — pulls top-20 from FTS and top-20 sessions from dense cosine, RRF-merges (k=60), returns top-N sessions with best snippet. Falls back to FTS-only if `Embedder.isAvailable == false` or the dense table is empty.
- Migration v17 — `corpus_embeddings(session_id, chunk_idx, text, vector, indexed_at)` + session_id index.
- Launch backfill — `CorpusIndexer.backfillIfEmpty` runs once on AppDelegate launch if the table is empty.
- `AskCorpusController` and `ProjectQAController` both call `HybridRetriever.retrieve` instead of `SessionSearch.search` directly.

Trade-off accepted for v1: `NLEmbedding` is older word2vec-style and lower quality than modern transformer embeddings. Still a large jump over lexical-only (it does bridge synonyms / paraphrases — the original "luxury cars" ↔ "Maserati" failure mode is fixed). v2 below swaps the embedder behind the same interface without touching retrieval logic.

## v2 — upgrade path

Pick this up as a dedicated session; ~1–2 days of focused work.

## Why

The current retriever is BM25 over SQLite FTS5 (`SessionSearch.swift`). It
prefix-matches tokens with AND. As `CLAUDE.md` notes:

> `"luxury cars"` won't match `"Maserati"`; strict AND on all tokens hurts
> recall for long natural questions.

The whole product premise — "ask anything across your meetings" — is gated
by retrieval quality. Lexical-only is the ceiling.

## Scope

1. Local sentence embeddings (no API call).
2. Per-session chunked index, persisted next to the SQLite FTS sidecar.
3. Hybrid retriever (FTS + dense, RRF-merged) replacing
   `AskCorpusController.retrieve` and `ProjectQAController.retrieve`.
4. Background re-index on first run for existing markdown corpus.

Out of scope for v1: reranking with a cross-encoder, per-speaker filters,
HNSW / approximate search.

## Tech choices (all already a dep)

- **Embedder:** `bge-small-en-v1.5` (~140 MB, 384-dim) via `swift-transformers`
  (`Hub` + `Tokenizers` packages already in `project.yml`). Alternative if
  multilingual matters: `paraphrase-multilingual-MiniLM-L12-v2` (~120 MB,
  384-dim). Pick at install time, store choice in Settings.
- **Inference:** MLX (also already a dep) for Apple-Silicon acceleration.
  Falls back to CoreML if MLX isn't available, but on the target hardware
  (Tristan's Mac) MLX is the path.
- **Storage:** SQLite. New table next to `transcript_entries`:
  ```sql
  CREATE TABLE corpus_embeddings (
      session_id TEXT NOT NULL,
      chunk_idx  INTEGER NOT NULL,
      start_ms   INTEGER,
      end_ms     INTEGER,
      text       TEXT NOT NULL,
      vector     BLOB NOT NULL,  -- 384 × float32 = 1536 bytes
      PRIMARY KEY (session_id, chunk_idx)
  );
  CREATE INDEX corpus_embeddings_session ON corpus_embeddings(session_id);
  ```
  No ANN structure in v1 — brute-force cosine over ~50k chunks is ~5 ms on
  M-series. Add HNSW only if/when scale demands it.

## Hardware budget

- Model on disk: 80–140 MB
- Resident RAM while embedding: 150–300 MB (unload after batch)
- Embed throughput on M-series: ~50–200 ms per chunk (a few hundred tokens)
- Index disk: ~1.5 KB per chunk; 1000 sessions × ~50 chunks = ~75 MB
- Query latency: model warm-load (~100 ms) + 1 embed (~50 ms) + cosine over
  index (~5 ms) ≈ **150 ms first query, ~60 ms subsequent**.

## Architecture sketch

```
RTI/Sources/Corpus/
├── Embedder.swift           // loads bge-small via swift-transformers + MLX
├── ChunkPolicy.swift        // ~300-token windows w/ ~50-token overlap
├── CorpusIndexer.swift      // writes corpus_embeddings rows for a session
├── CorpusIndexBackfill.swift// one-time pass over existing corpus markdown
└── HybridRetriever.swift    // RRF merge of SessionSearch + dense top-k
```

### Indexing pipeline

1. On session finalize (after the markdown file lands in `~/meetings/`),
   `CorpusIndexer` chunks the transcript by `ChunkPolicy`, embeds each chunk,
   and writes to `corpus_embeddings`. Atomic per chunk; resumable.
2. `CorpusIndexBackfill` walks `~/meetings/*.md` on first launch after this
   ships, queues missing sessions, processes them with a low-priority
   `OperationQueue`. Progress visible in Debug Console.
3. Settings UI: "Re-index all sessions" button (nuke + replay).

### Retrieval

`HybridRetriever.retrieve(question, k: 8) -> [CorpusChatCandidate]`:

1. Run `SessionSearch.search(question, k: 20)` — existing BM25.
2. Embed `question`. Cosine over `corpus_embeddings` → top 20 dense hits
   (grouped to session-level, max chunk score per session).
3. RRF merge: `score(s) = Σ 1 / (60 + rank_in_list)`.
4. Return top `k` sessions with their best chunk as snippet.

Both `AskCorpusController` and `ProjectQAController` swap their `retrieve`
override to call `HybridRetriever` with the project's session-id whitelist
applied where relevant.

### Failure modes

- Model file missing / corrupt → fall back to FTS-only with a one-time
  warning. Never block Ask.
- Index out of date (session edited externally) → `mtime` check on the
  markdown file vs `corpus_embeddings.indexed_at`; reindex async on read.
- Disk full → indexer pauses, surfaces error in Debug Console.

## Open questions for the implementation session

1. **Chunk granularity.** 300 tokens with 50 overlap is a starting point;
   measure recall on a held-out set of real Ask queries before committing.
2. **Model swap UX.** Should switching embedder force a full re-index? Probably
   yes — vectors are not cross-comparable across models.
3. **Settings surface.** A new "Retrieval" tab? Or fold into existing
   "Analysis" tab? Lean toward fold-in; one less surface to maintain.
4. **MLX model packaging.** Ship the model bundled, or download on first
   index? Bundled = bigger `.app`, no network at install. Download = smaller
   binary but first-run friction. Default to download with a clear progress
   indicator.

## What it unlocks

- Ask Your Corpus quality jumps from "did the user search for the right
  word?" to "did the meeting talk about the concept?"
- Project chat retrieval gets the same upgrade for free.
- Recap and summary generation can pull more relevant cross-session context.
- Foundation for future features: "find sessions similar to this one",
  "auto-cluster meetings into topics" — both are trivial once vectors exist.
