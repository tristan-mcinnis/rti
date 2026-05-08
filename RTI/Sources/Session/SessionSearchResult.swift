import Foundation

/// Data-only value type for a single FTS hit. Lives in its own file so
/// modules with no DB layer (unit-test bundle, MCP companion) can reference
/// it without dragging in GRDB / `RTIDatabase`.
struct SessionSearchResult: Identifiable {
    let id: String
    let session: Session
    let snippet: String
}
