import Foundation
import GRDB

/// Themes/quotes panel: a list of topics surfaced from the live (or
/// completed) transcript, each backed by speaker-labeled, timestamped
/// verbatim quotes. Stored as a single JSON blob per session because
/// each periodic regen overwrites the previous payload — no incremental
/// row-by-row diffing required.

struct ThemeQuote: Codable, Identifiable, Equatable {
    /// Stable id per (theme, position) so SwiftUI re-renders cleanly when
    /// the LLM revises the same theme. We don't persist the id separately;
    /// it's derived from index + topic title at decode time.
    var id: String { "\(timestampMs ?? -1)-\(text.hashValue)" }
    let speaker: String?
    let timestampMs: Int?
    let text: String

    var formattedTimestamp: String {
        guard let ms = timestampMs else { return "" }
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ThemeGroup: Codable, Identifiable, Equatable {
    var id: String { title }
    let title: String
    let summary: String?
    let quotes: [ThemeQuote]
}

struct ThemesPayload: Codable, Equatable {
    let themes: [ThemeGroup]

    static let empty = ThemesPayload(themes: [])
}

/// GRDB row mapping for `session_themes`. One row per session; the
/// payload is the latest themes pass (real-time or hi-fi).
struct SessionThemesRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_themes"

    var sessionId: String
    var payloadJson: String
    var generatedAt: Date
    var isHiFi: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case payloadJson = "payload_json"
        case generatedAt = "generated_at"
        case isHiFi = "is_hi_fi"
    }

    func payload() -> ThemesPayload {
        guard let data = payloadJson.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ThemesPayload.self, from: data) else {
            return .empty
        }
        return parsed
    }
}
