import Foundation

/// A moderated-interview discussion guide. Imported from a markdown or
/// text file the user picks; the LLM parses the raw document into a
/// structured Objective → Section → Question hierarchy that the matcher
/// can pair against the live transcript. Ephemeral — held in memory on the
/// controller for the session, never persisted.

enum GuideQuestionStatus: String, Codable, Equatable {
    case pending
    case partial
    case answered
}

enum GuideQuoteConfidence: String, Codable, Equatable {
    case high
    case medium
    case low
}

struct GuideQuote: Codable, Equatable, Identifiable {
    var id: String { "\(timestampMs ?? 0)-\(text.hashValue)" }
    let text: String
    let speaker: String?
    let timestampMs: Int?

    var formattedTimestamp: String {
        guard let ms = timestampMs else { return "" }
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct GuideQuestionResponse: Codable, Equatable {
    let summary: String
    let quotes: [GuideQuote]
    let confidence: GuideQuoteConfidence
    let lastUpdatedAt: Date
}

struct GuideQuestion: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    var status: GuideQuestionStatus
    var response: GuideQuestionResponse?
}

struct GuideSection: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var questions: [GuideQuestion]
}

struct GuideObjective: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let description: String?
    var sections: [GuideSection]
    var takeaway: String?
}

struct DiscussionGuide: Codable, Equatable {
    let id: String
    let fileName: String
    let parsedAt: Date
    var objectives: [GuideObjective]

    /// Total / answered / percent — the coverage row shown at the top of
    /// the panel.
    var coverage: (total: Int, answered: Int, percent: Int) {
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
    mutating func apply(matches: [GuideMatch]) {
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

    func unansweredQuestions() -> [GuideQuestion] {
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

struct GuideMatch: Codable, Equatable {
    let questionId: String
    let summary: String
    let quotes: [GuideQuote]
    let confidence: GuideQuoteConfidence
    /// Whether the new evidence is enough to close out the question or
    /// only partial. The matcher decides per match.
    let status: GuideQuestionStatus
}
