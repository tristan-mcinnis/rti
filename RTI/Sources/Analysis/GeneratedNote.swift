import Foundation

struct GeneratedNote: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let rangeStartMs: Int
    let rangeEndMs: Int
    let content: String
}
