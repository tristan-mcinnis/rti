import Foundation
import GRDB

/// Hybrid retrieval over the corpus: combines the existing BM25 FTS index
/// (`SessionSearch`) with the dense embedding index (`corpus_embeddings`)
/// via Reciprocal Rank Fusion. RRF needs no score calibration between the
/// two systems — it just averages the inverse ranks.
///
/// Falls back to FTS-only if the embedder is unavailable or the dense
/// index is empty (e.g. backfill hasn't run yet), so retrieval always
/// returns something useful.
enum HybridRetriever {

    /// One scored session result with its best chunk as a snippet.
    struct Result {
        let session: Session
        let bestSnippet: String?
        let score: Double
    }

    /// Retrieve up to `limit` sessions for `query`. Pulls top `perSystem`
    /// hits from each subsystem, RRF-merges them by session id, and
    /// returns the highest-scoring `limit` sessions with the snippet
    /// from whichever chunk contributed the strongest signal.
    static func retrieve(
        query: String,
        limit: Int = 8,
        perSystem: Int = 20,
        in dbReader: DatabaseReader = RTIDatabase.shared.pool
    ) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // FTS ranks: 0-based index in the results list = the rank.
        let ftsHits = SessionSearch.search(query: trimmed, limit: perSystem)
        let ftsRank: [String: Int] = Dictionary(
            uniqueKeysWithValues: ftsHits.enumerated().map { ($0.element.session.id, $0.offset) }
        )
        let ftsSnippet: [String: String] = Dictionary(
            uniqueKeysWithValues: ftsHits.compactMap { hit -> (String, String)? in
                guard !hit.snippet.isEmpty else { return nil }
                return (hit.session.id, hit.snippet)
            }
        )

        // Dense hits — one row per chunk; we group to per-session max
        // similarity below. Empty array if the embedder is offline or
        // the index is empty.
        let denseHits = denseSearch(query: trimmed, limit: perSystem * 4, in: dbReader)
        var perSessionDenseRank: [String: Int] = [:]
        var perSessionDenseSnippet: [String: String] = [:]
        var seen: Set<String> = []
        for hit in denseHits {
            if seen.insert(hit.sessionId).inserted {
                perSessionDenseRank[hit.sessionId] = perSessionDenseRank.count
                perSessionDenseSnippet[hit.sessionId] = hit.text
            }
            if perSessionDenseRank.count >= perSystem { break }
        }

        // RRF fusion. k=60 is the canonical constant from the original
        // Cormack et al. 2009 paper — robust enough that we don't tune.
        let k: Double = 60
        var fused: [String: Double] = [:]
        for (id, rank) in ftsRank {
            fused[id, default: 0] += 1.0 / (k + Double(rank))
        }
        for (id, rank) in perSessionDenseRank {
            fused[id, default: 0] += 1.0 / (k + Double(rank))
        }

        // Resolve session metadata. FTS hits already carry it; for
        // dense-only hits we look up via CorpusBackedStore.
        var sessionsById: [String: Session] = [:]
        for hit in ftsHits { sessionsById[hit.session.id] = hit.session }
        let allMarkdown = CorpusBackedStore.allMarkdownSessions()
        for s in allMarkdown where fused[s.id] != nil && sessionsById[s.id] == nil {
            sessionsById[s.id] = s
        }

        let ranked = fused
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { (id, score) -> Result? in
                guard let session = sessionsById[id] else { return nil }
                // Prefer the FTS snippet when present (it highlights the
                // match terms); fall back to the dense chunk text.
                let snippet = ftsSnippet[id] ?? perSessionDenseSnippet[id]
                return Result(session: session, bestSnippet: snippet, score: score)
            }

        // Smoking-gun log: how much of the final ranking came from
        // each subsystem, and crucially `denseOnly` — sessions the
        // embedder surfaced that FTS missed entirely. That number > 0
        // is the proof embeddings are doing useful work.
        let denseOnly = perSessionDenseRank.keys.filter { ftsRank[$0] == nil }.count
        let ftsOnly = ftsRank.keys.filter { perSessionDenseRank[$0] == nil }.count
        RTILog.log(
            "retrieve — fts=\(ftsHits.count) dense=\(denseHits.count) denseSessions=\(perSessionDenseRank.count) denseOnly=\(denseOnly) ftsOnly=\(ftsOnly) fused=\(fused.count) used=\(ranked.count)",
            category: "corpus"
        )
        return Array(ranked)
    }

    // MARK: - Dense scan

    private struct DenseHit {
        let sessionId: String
        let chunkIdx: Int
        let text: String
        let score: Float
    }

    /// Brute-force cosine over every row in `corpus_embeddings`. At our
    /// scale (target <50k chunks) this is ~5 ms — no ANN structure needed.
    /// Returns hits sorted descending by score.
    private static func denseSearch(
        query: String,
        limit: Int,
        in dbReader: DatabaseReader
    ) -> [DenseHit] {
        guard let qVec = Embedder.embed(query) else { return [] }

        let rows: [(String, Int, String, Data)] = (try? dbReader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT session_id, chunk_idx, text, vector
                FROM corpus_embeddings
            """).map { row in
                (row["session_id"] as String,
                 row["chunk_idx"] as Int,
                 row["text"] as String,
                 row["vector"] as Data)
            }
        }) ?? []
        guard !rows.isEmpty else { return [] }

        var scored: [DenseHit] = []
        scored.reserveCapacity(rows.count)
        for (sessionId, idx, text, blob) in rows {
            let v = EmbeddingBlob.decode(blob)
            let score = Embedder.cosine(qVec, v)
            scored.append(DenseHit(sessionId: sessionId, chunkIdx: idx, text: text, score: score))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }
}
