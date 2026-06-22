import Foundation

/// One proactive suggestion surfaced by Auto mode while a meeting runs.
/// Ephemeral, like findings: cards accumulate in memory for the session and are
/// dropped on `clear()`. Unlike findings (a research record), a card is an
/// in-the-moment nudge for the user — something to say, ask, recall, or flag,
/// grounded in the meeting's project context.
struct AutoAssistCard: Identifiable, Equatable {
    let id = UUID()
    /// Wall-clock time the card was surfaced.
    let timestamp: Date
    let kind: AutoCardKind
    /// The suggestion itself (one line; what to say / ask / recall).
    let text: String
    /// Why it's relevant right now (one short line), or empty.
    let why: String
    /// The project document or guide the suggestion draws on, when grounded in
    /// one (e.g. "00-status.md", "Group 1 transcript"), else nil.
    let source: String?
}

/// What kind of help a card offers. Drives its icon and label.
enum AutoCardKind: String, Codable, Equatable, CaseIterable {
    /// A line the user could say or a point to make now.
    case say
    /// A question worth asking / a thread to follow up.
    case ask
    /// A relevant fact from the project to surface (prior finding, what a
    /// participant said, a status detail) — the "they just asked about X" case.
    case recall
    /// Something to watch: a contradiction with the project record, a claim to
    /// verify, a risk.
    case flag

    /// Tolerant parse of whatever the model emitted.
    init(raw: String) {
        switch raw.uppercased() {
        case "SAY": self = .say
        case "ASK": self = .ask
        case "RECALL", "CONTEXT", "INFO": self = .recall
        case "FLAG", "WATCH": self = .flag
        default: self = .recall
        }
    }

    var label: String {
        switch self {
        case .say: "Say"
        case .ask: "Ask"
        case .recall: "Recall"
        case .flag: "Flag"
        }
    }

    var icon: String {
        switch self {
        case .say: "quote.bubble"
        case .ask: "questionmark.circle"
        case .recall: "books.vertical"
        case .flag: "exclamationmark.triangle"
        }
    }
}
