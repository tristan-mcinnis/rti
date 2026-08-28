import Foundation

/// One tagged work object in the live intelligence ledger. Ephemeral, like
/// notes: entries accumulate in memory for the session and are dropped on
/// `clear()`; `SessionArchive` writes the final set to disk at session end.
struct FindingEntry: Identifiable, Equatable {
    let id = UUID()
    /// Wall-clock time the finding was logged.
    let timestamp: Date
    /// Milliseconds into the session — drives the `[mm:ss]` stamp.
    let rangeMs: Int
    let tag: FindingTag
    /// What was decided/revealed/assigned (one line; may carry a key verbatim).
    let headline: String
    /// Why it matters or what should happen next (one line).
    let matters: String
    /// Short verbatim quote, when there was a quotable line.
    let quote: String?
    /// Speaker label, when clear.
    let speaker: String?
}

/// The kind of live intelligence object. The decision/action/question/risk
/// tags are the core RTI surface; the older research tags stay supported so
/// existing prompt overrides and in-flight model outputs do not break.
enum FindingTag: String, Codable, Equatable, CaseIterable {
    case decision
    case action
    case openQuestion
    case risk
    case followUp
    case finding
    case tension
    case contradiction
    case newThread
    case missed

    /// Tolerant parse of whatever the model emitted ("NEW_THREAD", "new thread",
    /// "THREAD" all map to `.newThread`); unknown → `.finding`.
    init(raw: String) {
        switch raw.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "DECISION", "AGREEMENT": self = .decision
        case "ACTION", "TASK", "TODO", "TO_DO": self = .action
        case "QUESTION", "OPEN_QUESTION", "OPENQUESTION": self = .openQuestion
        case "RISK", "BLOCKER", "ISSUE": self = .risk
        case "FOLLOW_UP", "FOLLOWUP", "FOLLOW-UP", "NEXT_STEP": self = .followUp
        case "TENSION": self = .tension
        case "CONTRADICTION": self = .contradiction
        case "NEW_THREAD", "NEWTHREAD", "THREAD": self = .newThread
        case "MISSED": self = .missed
        default: self = .finding
        }
    }

    var label: String {
        switch self {
        case .decision: "Decision"
        case .action: "Action"
        case .openQuestion: "Open question"
        case .risk: "Risk"
        case .followUp: "Follow-up"
        case .finding: "Finding"
        case .tension: "Tension"
        case .contradiction: "Contradiction"
        case .newThread: "New thread"
        case .missed: "Missed"
        }
    }

    var icon: String {
        switch self {
        case .decision: "checkmark.seal"
        case .action: "checklist"
        case .openQuestion: "questionmark.circle"
        case .risk: "exclamationmark.triangle"
        case .followUp: "arrowshape.turn.up.right"
        case .finding: "lightbulb"
        case .tension: "bolt.horizontal"
        case .contradiction: "arrow.triangle.2.circlepath"
        case .newThread: "sparkle"
        case .missed: "exclamationmark.bubble"
        }
    }
}

extension FindingEntry {
    /// Parse a lightweight structured user note. This keeps `/note` as the
    /// capture primitive while letting explicit marks enter the same source-
    /// linked ledger as model-detected decisions/actions/questions/risks.
    static func markedNote(from raw: String, startMs: Int) -> FindingEntry? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let specs: [(FindingTag, [String])] = [
            (.decision, ["decision", "decide", "decided", "agreement"]),
            (.action, ["action", "todo", "to-do", "task"]),
            (.openQuestion, ["question", "open question", "open-question"]),
            (.risk, ["risk", "blocker", "issue"]),
            (.followUp, ["followup", "follow-up", "follow up", "next step"]),
            (.finding, ["mark", "important", "note"]),
        ]

        let lower = trimmed.lowercased()
        for (tag, prefixes) in specs {
            for prefix in prefixes {
                guard lower.hasPrefix(prefix) else { continue }
                let rest = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = rest.first, [":", "-", "—"].contains(first) else { continue }
                let body = String(rest.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return FindingEntry(
                    timestamp: Date(),
                    rangeMs: startMs,
                    tag: tag,
                    headline: body,
                    matters: "Marked by user note.",
                    quote: body,
                    speaker: "User note"
                )
            }
        }
        return nil
    }
}
