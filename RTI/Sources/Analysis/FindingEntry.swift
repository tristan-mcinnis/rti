import Foundation

/// One tagged observation in the live Findings ledger. Ephemeral, like notes:
/// findings accumulate in memory for the session and are dropped on `clear()`;
/// `SessionArchive` writes the final set to disk at session end.
struct FindingEntry: Identifiable, Equatable {
    let id = UUID()
    /// Wall-clock time the finding was logged.
    let timestamp: Date
    /// Milliseconds into the session — drives the `[mm:ss]` stamp.
    let rangeMs: Int
    let tag: FindingTag
    /// What was said/revealed (one line; may carry a key verbatim).
    let headline: String
    /// Why it matters for the research objective (one line).
    let matters: String
    /// Short verbatim quote, when there was a quotable line.
    let quote: String?
    /// Speaker label, when clear.
    let speaker: String?
}

/// The kind of observation. Mirrors the listener-assist tag vocabulary so the
/// one-shot ⌘↵ flag and the accumulating ledger speak the same language.
enum FindingTag: String, Codable, Equatable, CaseIterable {
    case finding
    case tension
    case contradiction
    case newThread
    case missed

    /// Tolerant parse of whatever the model emitted ("NEW_THREAD", "new thread",
    /// "THREAD" all map to `.newThread`); unknown → `.finding`.
    init(raw: String) {
        switch raw.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "TENSION": self = .tension
        case "CONTRADICTION": self = .contradiction
        case "NEW_THREAD", "NEWTHREAD", "THREAD": self = .newThread
        case "MISSED": self = .missed
        default: self = .finding
        }
    }

    var label: String {
        switch self {
        case .finding: "Finding"
        case .tension: "Tension"
        case .contradiction: "Contradiction"
        case .newThread: "New thread"
        case .missed: "Missed"
        }
    }

    var icon: String {
        switch self {
        case .finding: "lightbulb"
        case .tension: "bolt.horizontal"
        case .contradiction: "arrow.triangle.2.circlepath"
        case .newThread: "sparkle"
        case .missed: "exclamationmark.bubble"
        }
    }
}
