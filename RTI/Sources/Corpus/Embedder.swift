import Foundation
import NaturalLanguage

/// Sentence-level embeddings for corpus chunks. v1 uses Apple's built-in
/// `NLEmbedding.sentenceEmbedding` — zero deps, zero install friction, 512-dim
/// English vectors. Quality is below modern transformer embeddings (bge-small,
/// MiniLM) but already a large jump over lexical-only retrieval because the
/// embedding bridges synonyms and paraphrases (`"luxury cars"` ↔ `"Maserati"`).
///
/// A v2 swap to bge-small via MLX + swift-transformers is sketched in
/// `docs/specs/embeddings.md` — keep the interface narrow so the swap is
/// confined to this file.
enum Embedder {
    /// Lazy-loaded, retained for process lifetime. Loading is ~10 ms; reuse
    /// across calls. The framework keeps the model memory-mapped, so RAM
    /// cost is bounded regardless of how many calls we make.
    nonisolated(unsafe) private static let model: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Vector dimensionality. 512 for English `sentenceEmbedding`. Returns
    /// 0 if the model failed to load (Embedder will then refuse to embed).
    static var dimension: Int { model?.dimension ?? 0 }

    /// True if the embedder is usable. False on platforms / OS versions
    /// where `NLEmbedding.sentenceEmbedding(for: .english)` returns nil
    /// — in that case callers should fall back to FTS-only retrieval.
    static var isAvailable: Bool { model != nil && (model?.dimension ?? 0) > 0 }

    /// Embed a single chunk of text. Returns nil if the model is
    /// unavailable or the input is empty. The returned `[Float]` has
    /// length `dimension` and is L2-normalised so cosine reduces to a
    /// plain dot product.
    static func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model else { return nil }
        guard let raw = model.vector(for: trimmed) else { return nil }
        var v = raw.map { Float($0) }
        normalise(&v)
        return v
    }

    /// L2-normalise in place. Vectors with near-zero magnitude (e.g. empty
    /// input slipped through) are left zeroed.
    private static func normalise(_ v: inout [Float]) {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let mag = sqrt(sumSq)
        guard mag > 1e-6 else { return }
        for i in v.indices { v[i] /= mag }
    }

    /// Cosine similarity between two pre-normalised vectors. Equivalent
    /// to a plain dot product when both inputs come from `embed(_:)`.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var dot: Float = 0
        for i in 0..<n { dot += a[i] * b[i] }
        return dot
    }
}

/// Pack / unpack a `[Float]` to/from the BLOB column in `corpus_embeddings`.
/// Little-endian Float32, host byte order — fine since we only ever read
/// the index on the same machine that wrote it.
enum EmbeddingBlob {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: buf.baseAddress, count: count))
        }
    }
}
