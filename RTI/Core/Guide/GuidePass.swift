import Foundation

/// Untrusted model output. Text and speaker attribution always come from local turns.
/// Decoding is tolerant (`GuidePass+Decoding`): a bad field drops that field,
/// never the cells around it.
public struct GuidePass: Sendable {
    public struct Quote: Sendable {
        public let turn: String
        public let english: String
    }

    public struct Vote: Sendable {
        public let turn: String
        public let choice: String
        /// A moderator's spoken tally of a show of hands carries the count.
        public let count: Int?
        /// "moderator_tally" for a spoken tally; nil for a respondent's own pick.
        public let source: String?

        public init(turn: String, choice: String, count: Int? = nil, source: String? = nil) {
            self.turn = turn
            self.choice = choice
            self.count = count
            self.source = source
        }

        public var isTally: Bool {
            count != nil
        }
    }

    public struct Cell: Sendable {
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

    /// Nothing to file and no position: the back-off counts these.
    public var isEmpty: Bool {
        suggestion == nil && cells.isEmpty
    }

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

// MARK: - Tolerant decoding

/// One element that may fail to decode without failing its array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lossyArray<Value: Decodable>(_: Value.Type, forKey key: Key) -> [Value] {
        (try? decodeIfPresent([Lossy<Value>].self, forKey: key))?.compactMap(\.value) ?? []
    }

    /// A string, or a number written without quotes.
    func looseString(forKey key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    func looseInt(forKey key: Key) -> Int? {
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        return (try? decodeIfPresent(String.self, forKey: key)).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

extension GuidePass: Decodable {
    private enum CodingKeys: String, CodingKey {
        case suggestion, evidence, cells
    }

    /// The suggestion as an object: `{"qid":"S3Q2"}` or `{"qid":"S3Q2","ids":[...]}`.
    private struct SuggestionObject: Decodable {
        let qid: String?
        let ids: [String]

        private enum CodingKeys: String, CodingKey {
            case qid, ids, evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            qid = container.looseString(forKey: .qid)
            ids = container.lossyArray(String.self, forKey: .ids) + container.lossyArray(String.self, forKey: .evidence)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var evidence = container.lossyArray(String.self, forKey: .evidence)
        if let text = container.looseString(forKey: .suggestion) {
            suggestion = text
        } else if let object = try? container.decodeIfPresent(SuggestionObject.self, forKey: .suggestion) {
            suggestion = object.qid
            evidence += object.ids.filter { !evidence.contains($0) }
        } else {
            suggestion = nil
        }
        self.evidence = evidence
        cells = container.lossyArray(Cell.self, forKey: .cells)
    }
}

extension GuidePass.Cell: Decodable {
    private enum CodingKeys: String, CodingKey {
        case qid, coverage, summary, turns, quotes, votes
    }

    /// Only the qid is required; every other field falls back on its own.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let qid = container.looseString(forKey: .qid) else {
            throw DecodingError.keyNotFound(CodingKeys.qid, .init(codingPath: decoder.codingPath, debugDescription: "A cell needs a qid."))
        }
        self.init(qid: qid,
                  coverage: container.looseString(forKey: .coverage) ?? "Lightly covered",
                  summary: (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? "",
                  turns: container.lossyArray(String.self, forKey: .turns),
                  quotes: container.lossyArray(GuidePass.Quote.self, forKey: .quotes),
                  votes: container.lossyArray(GuidePass.Vote.self, forKey: .votes))
    }
}

extension GuidePass.Quote: Decodable {
    private enum CodingKeys: String, CodingKey {
        case turn, english
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let turn = container.looseString(forKey: .turn) else {
            throw DecodingError.keyNotFound(CodingKeys.turn, .init(codingPath: decoder.codingPath, debugDescription: "A quote needs a turn."))
        }
        self.init(turn: turn, english: (try? container.decodeIfPresent(String.self, forKey: .english)) ?? "")
    }
}

extension GuidePass.Vote: Decodable {
    private enum CodingKeys: String, CodingKey {
        case turn, choice, count, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let turn = container.looseString(forKey: .turn), let choice = container.looseString(forKey: .choice) else {
            throw DecodingError.keyNotFound(CodingKeys.choice, .init(codingPath: decoder.codingPath, debugDescription: "A vote needs a turn and a choice."))
        }
        let count = container.looseInt(forKey: .count).flatMap { $0 > 0 ? $0 : nil }
        self.init(turn: turn, choice: choice, count: count, source: count == nil ? nil : (container.looseString(forKey: .source) ?? "moderator_tally"))
    }
}
