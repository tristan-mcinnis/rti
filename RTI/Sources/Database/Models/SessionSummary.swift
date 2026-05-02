import Foundation

/// In-memory session summary for the UI layer. No longer GRDB-backed —
/// canonical storage is the markdown body under `~/meetings/` plus
/// SummaryController's in-memory cache for in-flight summaries.
struct SessionSummary: Identifiable, Hashable {
    var id: String
    var sessionId: String
    var summaryText: String
    var actionItems: String?
    var keyTopics: String?
    var decisions: String?
    var followUps: String?
    var rawResponse: String?
    var createdAt: Date
    var regeneratedAt: Date?
}
