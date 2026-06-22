import Foundation

// A moderated-interview discussion guide. Imported from a markdown or text file
// the user picks; the LLM parses the raw document into a structured
// Objective → Section → Question hierarchy that the matcher can pair against the
// live transcript. Ephemeral — held in memory on the controller for the
// session, never persisted.

public enum GuideQuestionStatus: String, Codable, Equatable {
    case pending
    case partial
    case answered
}

public enum GuideQuoteConfidence: String, Codable, Equatable {
    case high
    case medium
    case low
}

public struct GuideQuote: Codable, Equatable, Identifiable {
    public var id: String {
        "\(timestampMs ?? 0)-\(text.hashValue)"
    }

    public let text: String
    public let speaker: String?
    public let timestampMs: Int?

    public init(text: String, speaker: String?, timestampMs: Int?) {
        self.text = text
        self.speaker = speaker
        self.timestampMs = timestampMs
    }

    public var formattedTimestamp: String {
        guard let ms = timestampMs else { return "" }
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct GuideQuestionResponse: Codable, Equatable {
    public let summary: String
    public let quotes: [GuideQuote]
    public let confidence: GuideQuoteConfidence
    public let lastUpdatedAt: Date
}

public struct GuideQuestion: Codable, Identifiable, Equatable {
    public let id: String
    public let text: String
    public var status: GuideQuestionStatus
    public var response: GuideQuestionResponse?

    public init(id: String, text: String, status: GuideQuestionStatus, response: GuideQuestionResponse?) {
        self.id = id
        self.text = text
        self.status = status
        self.response = response
    }
}

public struct GuideSection: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public var questions: [GuideQuestion]

    public init(id: String, title: String, questions: [GuideQuestion]) {
        self.id = id
        self.title = title
        self.questions = questions
    }
}

public struct GuideObjective: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let description: String?
    public var sections: [GuideSection]
    public var takeaway: String?

    public init(id: String, title: String, description: String?, sections: [GuideSection], takeaway: String?) {
        self.id = id
        self.title = title
        self.description = description
        self.sections = sections
        self.takeaway = takeaway
    }
}

public struct DiscussionGuide: Codable, Equatable {
    public let id: String
    public let fileName: String
    public let parsedAt: Date
    public var objectives: [GuideObjective]

    public init(id: String, fileName: String, parsedAt: Date, objectives: [GuideObjective]) {
        self.id = id
        self.fileName = fileName
        self.parsedAt = parsedAt
        self.objectives = objectives
    }

    /// Total / answered / percent — the coverage row shown at the top of
    /// the panel.
    public var coverage: (total: Int, answered: Int, percent: Int) {
        var total = 0
        var answered = 0
        for obj in objectives {
            for sec in obj.sections {
                for q in sec.questions {
                    total += 1
                    if q.status == .answered { answered += 1 }
                }
            }
        }
        let percent = total == 0 ? 0 : Int((Double(answered) / Double(total) * 100.0).rounded())
        return (total, answered, percent)
    }

    /// Apply a batch of matches from the periodic matcher. Existing
    /// quotes are preserved; new quotes are appended; status is overwritten.
    public mutating func apply(matches: [GuideMatch]) {
        let byId = Dictionary(uniqueKeysWithValues: matches.map { ($0.questionId, $0) })
        for o in objectives.indices {
            for s in objectives[o].sections.indices {
                for q in objectives[o].sections[s].questions.indices {
                    let question = objectives[o].sections[s].questions[q]
                    guard let match = byId[question.id] else { continue }
                    let existing = question.response?.quotes ?? []
                    let novel = match.quotes.filter { new in
                        !existing.contains { $0.text == new.text }
                    }
                    objectives[o].sections[s].questions[q].status = match.status
                    objectives[o].sections[s].questions[q].response = GuideQuestionResponse(
                        summary: match.summary,
                        quotes: existing + novel,
                        confidence: match.confidence,
                        lastUpdatedAt: Date()
                    )
                }
            }
        }
    }

    /// A compact text rendering of the guide for injection into the assistant's
    /// prompt, so the assist panel can answer questions about it ("what's left to
    /// cover?", "what did they say on pricing?", "what should I ask next?").
    /// Each question carries a status marker and, where the live matcher has
    /// found evidence, a one-line summary of what was said. Kept terse so it
    /// doesn't bloat every turn.
    public func assistantContextSummary() -> String {
        func marker(_ s: GuideQuestionStatus) -> String {
            switch s {
            case .answered: return "[x]"
            case .partial: return "[~]"
            case .pending: return "[ ]"
            }
        }
        let cov = coverage
        var lines: [String] = [
            "Discussion guide: \(fileName) — \(cov.answered)/\(cov.total) covered (\(cov.percent)%). "
                + "Markers: [x] answered, [~] partially covered, [ ] not yet covered.",
        ]
        for obj in objectives {
            lines.append("\n## \(obj.title)")
            if let d = obj.description, !d.isEmpty { lines.append("  (\(d))") }
            for sec in obj.sections {
                lines.append("### \(sec.title)")
                for q in sec.questions {
                    lines.append("\(marker(q.status)) \(q.text)")
                    if let summary = q.response?.summary, !summary.isEmpty {
                        lines.append("    → so far: \(summary)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public func unansweredQuestions() -> [GuideQuestion] {
        var out: [GuideQuestion] = []
        for o in objectives {
            for s in o.sections {
                for q in s.questions where q.status != .answered {
                    out.append(q)
                }
            }
        }
        return out
    }
}

public struct GuideMatch: Codable, Equatable {
    public let questionId: String
    public let summary: String
    public let quotes: [GuideQuote]
    public let confidence: GuideQuoteConfidence
    /// Whether the new evidence is enough to close out the question or
    /// only partial. The matcher decides per match.
    public let status: GuideQuestionStatus

    public init(
        questionId: String,
        summary: String,
        quotes: [GuideQuote],
        confidence: GuideQuoteConfidence,
        status: GuideQuestionStatus
    ) {
        self.questionId = questionId
        self.summary = summary
        self.quotes = quotes
        self.confidence = confidence
        self.status = status
    }

    // Tolerant decode: only `questionId` is required. Models occasionally typo a
    // field (e.g. "queries" instead of "quotes") or omit one; rather than let
    // that drop the whole match (and the rest of the batch alongside it), we
    // default the soft fields. `quotes` defaults to none, confidence to medium,
    // status to partial, summary to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionId = try c.decode(String.self, forKey: .questionId)
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        quotes = (try? c.decode([GuideQuote].self, forKey: .quotes)) ?? []
        confidence = (try? c.decode(GuideQuoteConfidence.self, forKey: .confidence)) ?? .medium
        status = (try? c.decode(GuideQuestionStatus.self, forKey: .status)) ?? .partial
    }
}
