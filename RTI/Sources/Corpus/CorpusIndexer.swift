import Foundation
import GRDB

/// Writes embedding rows into `corpus_embeddings` for every chunk of every
/// session in the corpus directory. Mirrors the call sites of
/// `CorpusFTSReindexer` so any session that gets its FTS rows rebuilt also
/// gets its dense index rebuilt.
///
/// Cheap to run: NLEmbedding is ~10 ms per chunk on Apple Silicon, and
/// `reindex` writes inside a single transaction.
enum CorpusIndexer {

    /// Rebuild the dense index from a corpus directory. Wipes
    /// `corpus_embeddings` and re-inserts from markdown summary +
    /// transcript bodies.
    ///
    /// No-op (early return) if the platform's `NLEmbedding` is
    /// unavailable — retrieval falls back to lexical-only, no error.
    static func reindex(
        from directory: URL,
        in dbWriter: DatabaseWriter
    ) throws {
        guard Embedder.isAvailable else {
            RTILog.log("reindex skipped — NLEmbedding unavailable", category: "corpus")
            return
        }

        let started = Date()
        let urls = (try? CorpusReader.listMarkdownFiles(in: directory)) ?? []
        var sessionCount = 0
        var chunkCount = 0
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM corpus_embeddings")
            for url in urls {
                guard let entry = try? CorpusReader.read(url) else { continue }
                let added = try indexEntry(entry, in: db)
                if added > 0 { sessionCount += 1 }
                chunkCount += added
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        RTILog.log(
            "reindex — sessions=\(sessionCount) chunks=\(chunkCount) dim=\(Embedder.dimension) ms=\(ms)",
            category: "corpus"
        )
    }

    /// Reindex a single session (used when one session finalises but the
    /// rest of the corpus is unchanged). Removes prior rows for the
    /// session before inserting fresh ones.
    static func reindexSession(
        id sessionId: String,
        from directory: URL,
        in dbWriter: DatabaseWriter
    ) throws {
        guard Embedder.isAvailable else { return }

        let urls = (try? CorpusReader.listMarkdownFiles(in: directory)) ?? []
        for url in urls {
            guard let entry = try? CorpusReader.read(url),
                  entry.frontmatter.id == sessionId else { continue }
            try dbWriter.write { db in
                try db.execute(
                    sql: "DELETE FROM corpus_embeddings WHERE session_id = ?",
                    arguments: [sessionId]
                )
                try indexEntry(entry, in: db)
            }
            return
        }
    }

    /// One-shot backfill called at app launch. No-op when the table is
    /// already populated — costs one COUNT(*). When empty (fresh install,
    /// or first launch after the v17 migration), kicks off a full
    /// reindex on a background queue so launch isn't blocked.
    static func backfillIfEmpty(
        from directory: URL,
        in dbWriter: DatabaseWriter
    ) {
        guard Embedder.isAvailable else {
            RTILog.log("backfill skipped — NLEmbedding unavailable", category: "corpus")
            return
        }
        let count: Int = (try? dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_embeddings") ?? 0
        }) ?? 0
        if count > 0 {
            RTILog.log("backfill skipped — index already populated (\(count) chunks)", category: "corpus")
            return
        }
        RTILog.log("backfill starting — dense index is empty", category: "corpus")
        Task.detached(priority: .background) {
            do {
                try reindex(from: directory, in: dbWriter)
            } catch {
                RTILog.log("backfill failed — \(error)", category: "corpus")
            }
        }
    }

    // MARK: - Per-entry

    @discardableResult
    private static func indexEntry(_ entry: CorpusEntry, in db: Database) throws -> Int {
        let id = entry.frontmatter.id
        let (summary, transcript) = CorpusFTSReindexer.splitBody(entry.body)

        // Index summary and transcript separately so a chunk's text in
        // the DB matches what the model embedded — keeps snippet display
        // honest with what was actually scored.
        let summaryChunks = ChunkPolicy.split(summary)
        let transcriptChunks = ChunkPolicy.split(transcript)

        var idx = 0
        let now = Date()

        for chunk in summaryChunks {
            guard let vec = Embedder.embed(chunk.text) else { continue }
            try insertRow(db: db, sessionId: id, idx: idx, text: chunk.text, vector: vec, at: now)
            idx += 1
        }
        for chunk in transcriptChunks {
            guard let vec = Embedder.embed(chunk.text) else { continue }
            try insertRow(db: db, sessionId: id, idx: idx, text: chunk.text, vector: vec, at: now)
            idx += 1
        }
        return idx
    }

    private static func insertRow(
        db: Database, sessionId: String, idx: Int,
        text: String, vector: [Float], at indexedAt: Date
    ) throws {
        try db.execute(sql: """
            INSERT INTO corpus_embeddings
                (session_id, chunk_idx, text, vector, indexed_at)
            VALUES (?, ?, ?, ?, ?)
        """, arguments: [
            sessionId, idx, text, EmbeddingBlob.encode(vector), indexedAt
        ])
    }
}
