import Foundation

/// Untrusted model output. Text and speaker attribution always come from local turns.
public struct GuidePass: Decodable, Sendable {
    public struct Quote: Decodable, Sendable {
        public let turn: String
        public let english: String
    }

    public struct Vote: Decodable, Sendable {
        public let turn: String
        public let choice: String
    }

    public struct Cell: Decodable, Sendable {
        public let qid: String
        public let coverage: String
        public let summary: String
        public let turns: [String]
        public let quotes: [Quote]
        public let votes: [Vote]
    }

    public let suggestion: String?
    public let evidence: [String]
    public let cells: [Cell]

    /// A timestamped manual selection owns its evidence, even when a model
    /// chooses a different question. A note for a mixed or redirected question
    /// cannot safely be split; its individually evidenced quotes and votes can.
    public func routing(_ manualQuestion: (String) -> String?) -> Self {
        var routed: [Cell] = []
        for cell in cells {
            var byQuestion: [String: [String]] = [:]
            var order: [String] = []
            for turn in cell.turns {
                let qid = manualQuestion(turn) ?? cell.qid
                if byQuestion[qid] == nil {
                    order.append(qid)
                }
                byQuestion[qid, default: []].append(turn)
            }
            for qid in order {
                guard let turns = byQuestion[qid] else { continue }
                let ids = Set(turns)
                let sameQuestion = order.count == 1 && qid == cell.qid
                routed.append(Cell(qid: qid, coverage: cell.coverage, summary: sameQuestion ? cell.summary : "",
                                   turns: turns, quotes: cell.quotes.filter { ids.contains($0.turn) },
                                   votes: cell.votes.filter { ids.contains($0.turn) }))
            }
        }
        return Self(suggestion: suggestion, evidence: evidence, cells: routed)
    }
}

public struct GuideSpeaker: Equatable, Sendable {
    public let participant: String
    public let isModerator: Bool
    public let seatCode: String?

    public init(participant: String, isModerator: Bool = false, seatCode: String? = nil) {
        self.participant = participant
        self.isModerator = isModerator
        self.seatCode = seatCode
    }
}
