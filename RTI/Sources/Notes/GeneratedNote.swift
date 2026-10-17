import Foundation

struct GeneratedNote: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let rangeStartMs: Int
    let rangeEndMs: Int
    /// Short title for this time-block (e.g. "Wear vs. Acme mapping").
    let title: String
    let content: String
}
