import Foundation

/// One guide question the moderator has moved past with no or thin evidence.
/// Derived on each guide pass; nothing here is stored or archived.
public struct GuideGap: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// The question came before the recording reached the guide: it was
        /// probably asked before Record, so it is no gap to go back to.
        case notRecorded
        /// Its section closed with no evidence filed.
        case skipped
        /// Live labels are off by default, so evidence is counted in quotes, not people.
        /// Zero quotes means only a note or a vote touched the question.
        case thin(quotes: Int)
        /// Every quote came from one roster seat in a group with more than one seat.
        case oneSeat(quotes: Int)
    }

    public let qid: String
    public let title: String
    public let titleZH: String?
    public let state: State

    public var id: String {
        qid
    }

    /// A gap the moderator can still go back to. A question asked before the
    /// recording started is not one.
    public var isActionable: Bool {
        state != .notRecorded
    }

    public var detail: String {
        switch state {
        case .notRecorded:
            "Not recorded"
        case .skipped:
            "Skipped"
        case let .thin(quotes):
            quotes == 0 ? "Thin: mentioned, no quotes" : "Thin: \(Self.count(quotes))"
        case let .oneSeat(quotes):
            "Thin: one seat, \(Self.count(quotes))"
        }
    }

    private static func count(_ quotes: Int) -> String {
        "\(quotes) \(quotes == 1 ? "quote" : "quotes")"
    }

    public init(qid: String, title: String, titleZH: String?, state: State) {
        self.qid = qid
        self.title = title
        self.titleZH = titleZH
        self.state = state
    }
}

/// Turns stored guide coverage into "what I missed": questions already passed
/// that were skipped or covered thinly. A pure function: no LLM call, no state.
///
/// A question is skipped only once its section has closed (the furthest
/// question is in a later section), because moderators reorder questions
/// inside a section. Skipped questions before `recordedFromIndex` (see
/// `recordedFrom`) are `notRecorded`.
/// "Moderator to…" instruction items are never gaps.
public enum GuideGaps {
    public static let limit = 5
    static let minimumEvidence = 2

    public static func find(
        questions: [GuideDocument.Question],
        cells: [GuideCell],
        furthestIndex: Int,
        currentQID: String?,
        rosterSize: Int?,
        recordedFromIndex: Int = 0,
        includeNotRecorded: Bool = false
    ) -> [GuideGap] {
        let cellsByID = Dictionary(cells.map { ($0.qid, $0) }, uniquingKeysWith: { first, _ in first })
        let furthestSection = questions.indices.contains(furthestIndex) ? section(of: questions[furthestIndex].qid) : nil
        var gaps: [GuideGap] = []
        for index in questions.indices.reversed() where index < furthestIndex {
            let question = questions[index]
            guard question.qid != currentQID, !GuideMatcher.isInstruction(question),
                  var state = state(of: cellsByID[question.qid], rosterSize: rosterSize) else { continue }
            if state == .skipped {
                if index < recordedFromIndex {
                    state = .notRecorded
                } else if section(of: question.qid) == furthestSection {
                    continue
                }
            }
            guard state != .notRecorded || includeNotRecorded else { continue }
            gaps.append(gap(question, state: state))
            if gaps.count == limit {
                break
            }
        }
        return gaps
    }

    /// The first guide index a recording covers, from the first index it
    /// reached early on (nil when none was reached early). A recording that
    /// first reached a later section started mid-guide: the earlier sections
    /// were asked before Record and are `notRecorded`. A first reach inside
    /// the first section is a normal start, maybe with a skip, so nothing is
    /// hidden: a skipped S1Q1 stays a gap to go back to.
    public static func recordedFrom(questions: [GuideDocument.Question], firstReachedIndex: Int?) -> Int {
        guard let index = firstReachedIndex, questions.indices.contains(index), let first = questions.first else { return 0 }
        let reachedSection = section(of: questions[index].qid)
        guard reachedSection != section(of: first.qid) else { return 0 }
        return questions.firstIndex { section(of: $0.qid) == reachedSection } ?? 0
    }

    /// "S2" for "S2Q5": `GuideDocument.parse` requires every qid to start
    /// with its section ID and "Q".
    static func section(of qid: String) -> String {
        guard let marker = qid.lastIndex(of: "Q") else { return qid }
        return String(qid[..<marker])
    }

    /// The state of a passed question, or nil when its evidence is sufficient.
    static func state(of cell: GuideCell?, rosterSize: Int?) -> GuideGap.State? {
        guard let cell else { return .skipped }
        if cell.hasHandTally {
            return nil
        }
        let quotes = cell.orderedQuotes
        switch cell.displayCoverage(passed: true) {
        case "Skipped":
            return .skipped
        case "Lightly covered":
            return .thin(quotes: quotes.count)
        case "Answered":
            let seats = Set(quotes.compactMap(\.seatCode).filter { !$0.isEmpty })
            // One unseated quote means seats under-count who spoke (labels off or
            // only partly assigned), so count quotes, as with no seats at all.
            if seats.isEmpty || quotes.contains(where: { ($0.seatCode ?? "").isEmpty }) {
                return quotes.count >= minimumEvidence ? nil : .thin(quotes: quotes.count)
            }
            // Every quote is seated: count seats. A one-seat roster (an IDI) is
            // answered by its one respondent; in a group, one seat alone is thin.
            let needed = min(minimumEvidence, max(1, rosterSize ?? minimumEvidence))
            if seats.count >= needed {
                return nil
            }
            return quotes.count >= minimumEvidence ? .oneSeat(quotes: quotes.count) : .thin(quotes: quotes.count)
        default:
            return nil
        }
    }

    private static func gap(_ question: GuideDocument.Question, state: GuideGap.State) -> GuideGap {
        let english = question.en.trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese = question.zh.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = english.isEmpty ? (chinese.isEmpty ? question.qid : chinese) : english
        let titleZH = english.isEmpty || chinese.isEmpty ? nil : chinese
        return GuideGap(qid: question.qid, title: title, titleZH: titleZH, state: state)
    }
}
