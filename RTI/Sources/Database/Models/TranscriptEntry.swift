import Foundation

/// In-memory transcript line for the UI layer. No longer GRDB-backed —
/// canonical storage is the markdown body under `~/meetings/`. Entries
/// are reconstructed from the body's `## Transcript` section by
/// `CorpusBackedStore`.
struct TranscriptEntry: Identifiable, Hashable {
    var id: String
    var sessionId: String
    var speakerId: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double
    var isFinal: Bool
    var createdAt: Date
}
