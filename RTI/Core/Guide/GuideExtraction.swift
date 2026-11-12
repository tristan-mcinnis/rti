import Foundation

public struct GuideQuote: Codable, Equatable, Sendable {
    public fileprivate(set) var participant: String
    public fileprivate(set) var locator: String
    public let original: String
    public let english: String
    public let rawSpeaker: String
    public let liveStartMs: Int
    public let turnID: String
    public fileprivate(set) var seatCode: String?
    public fileprivate(set) var verification: String?
    public fileprivate(set) var upgradedSpeaker: String?

    enum CodingKeys: String, CodingKey {
        case participant, locator, original, english, verification
        case rawSpeaker = "raw_speaker"
        case liveStartMs = "live_start_ms"
        case turnID = "turn_id"
        case seatCode = "seat_code"
        case upgradedSpeaker = "upgraded_speaker"
    }
}

private struct NoteEvidence: Codable, Equatable, Sendable {
    let summary: String
    let speakers: [String]
    let turnIDs: [String]
    let substantial: Bool
}

private struct VoteEvidence: Codable, Equatable, Sendable {
    let turn: String
    let speaker: String
    let choice: String
}

public struct GuideCell: Codable, Equatable, Sendable {
    public let qid: String
    public fileprivate(set) var coverage = "Not covered"
    public fileprivate(set) var summary = ""
    public fileprivate(set) var quotes: [GuideQuote] = []
    public fileprivate(set) var tally: String?
    public let score: Double?
    public fileprivate(set) var who = ""

    // The minimal provenance needed to retract a former moderator's contribution
    // and recompute a vote after two speaker IDs are assigned to one seat.
    fileprivate var notes: [NoteEvidence] = []
    fileprivate var votes: [VoteEvidence] = []

    fileprivate init(qid: String) {
        self.qid = qid
        score = nil
    }

    private enum CodingKeys: String, CodingKey {
        case qid, coverage, summary, quotes, tally, score, who
        case notes = "note_evidence"
        case votes = "vote_evidence"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(qid, forKey: .qid)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(summary, forKey: .summary)
        try c.encode(quotes, forKey: .quotes)
        try c.encode(tally, forKey: .tally)
        try c.encode(score, forKey: .score)
        try c.encode(who, forKey: .who)
        try c.encode(notes, forKey: .notes)
        try c.encode(votes, forKey: .votes)
    }
}

public struct GuideExtraction: Codable, Equatable, Sendable {
    public let group: String
    public var transcript: String
    public var segment: String
    public let source: String
    public private(set) var cells: [GuideCell]
    public var captureIncomplete = false

    enum CodingKeys: String, CodingKey {
        case group, transcript, segment, source, cells
        case captureIncomplete = "capture_incomplete"
    }

    public init(group: String, transcript: String, guide: GuideDocument) {
        self.group = Self.groupCode(group)
        self.transcript = transcript
        segment = ""
        source = "rti-live"
        cells = guide.questions.map { GuideCell(qid: $0.qid) }
    }

    private static func groupCode(_ group: String) -> String {
        let normalized = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.wholeMatch(of: /G[1-9][0-9]*/) == nil ? "" : normalized
    }

    public static func fileName(for group: String) -> String {
        let code = groupCode(group)
        return "guide-cells-\(code.isEmpty ? "unassigned" : code).json"
    }

    public var fileName: String {
        Self.fileName(for: group)
    }

    public static func locator(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func respondent(_ raw: String, _ speakers: [String: GuideSpeaker]) -> GuideSpeaker? {
        // Only positively identified system-leg turns can supply participant evidence.
        guard raw.hasPrefix("remote_"), let label = SpeakerLabelMapping.displayLabel(forRawKey: raw) else { return nil }
        let speaker = speakers[raw] ?? GuideSpeaker(participant: label)
        return speaker.isModerator ? nil : speaker
    }

    public mutating func apply(_ pass: GuidePass, turns: [GuideTurn], speakers: [String: GuideSpeaker],
                               rosterBase: Int?, allows: (String, String) -> Bool = { _, _ in true })
    {
        let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for proposed in pass.cells {
            guard let index = cells.firstIndex(where: { $0.qid == proposed.qid }) else { continue }
            func turn(_ id: String) -> GuideTurn? {
                guard allows(proposed.qid, id), let turn = byID[id], !turn.text.isEmpty,
                      Self.respondent(turn.speaker, speakers) != nil else { return nil }
                return turn
            }
            var cell = cells[index]
            let cited = Set(proposed.turns)
            let supported = proposed.turns.compactMap(turn)
            let summary = proposed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !supported.isEmpty, supported.count == proposed.turns.count, Self.isUsableSummary(summary),
               !cell.notes.contains(where: { Set($0.turnIDs) == Set(proposed.turns) })
            {
                cell.notes.append(NoteEvidence(summary: summary, speakers: supported.map(\.speaker), turnIDs: proposed.turns,
                                               substantial: proposed.coverage == "Answered"))
            }
            for quote in proposed.quotes where cell.quotes.count < 4 {
                guard cited.contains(quote.turn), let original = turn(quote.turn), let speaker = Self.respondent(original.speaker, speakers),
                      !cell.quotes.contains(where: { $0.turnID == original.id }) else { continue }
                cell.quotes.append(GuideQuote(participant: speaker.participant, locator: Self.locator(original.startMs),
                                              original: original.text, english: quote.english, rawSpeaker: original.speaker,
                                              liveStartMs: original.startMs, turnID: original.id, seatCode: speaker.seatCode))
            }
            for vote in proposed.votes {
                let choice = vote.choice.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cited.contains(vote.turn), let source = turn(vote.turn), !choice.isEmpty,
                      Self.containsChoice(choice, in: source.text),
                      !cell.votes.contains(where: { $0.turn == vote.turn && $0.choice == choice }) else { continue }
                cell.votes.append(VoteEvidence(turn: source.id, speaker: source.speaker, choice: choice))
            }
            cells[index] = cell
        }
        remap(speakers: speakers, rosterBase: rosterBase)
    }

    private static func isUsableSummary(_ summary: String) -> Bool {
        guard !summary.isEmpty else { return false }
        let lower = summary.lowercased()
        return !["insufficient data", "n/a", "tbd", "no data"].contains(where: lower.contains)
    }

    private static func containsChoice(_ choice: String, in text: String) -> Bool {
        // "A" in "handle" is no vote. ASCII boundaries also work in mixed Mandarin,
        // e.g. "我选A", where a Unicode word boundary would reject the choice.
        let startsWithWord = choice.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        let endsWithWord = choice.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        let prefix = startsWithWord ? "(?<![A-Za-z0-9])" : ""
        let suffix = endsWithWord ? "(?![A-Za-z0-9])" : ""
        let pattern = prefix + NSRegularExpression.escapedPattern(for: choice) + suffix
        return text.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
    }

    /// Pick complete sentences within the workbook limit. Preference alternates
    /// between the latest and earliest evidence; the output stays chronological.
    private static func briefSummary(_ cell: GuideCell) -> String {
        var sentences: [String] = []
        for note in cell.notes {
            let text = note.summary
            text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .bySentences) { sentence, _, _, _ in
                if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !sentence.isEmpty, sentence.unicodeScalars.count < 480, !sentences.contains(sentence)
                {
                    sentences.append(sentence)
                }
            }
        }
        var selected: [Int] = []
        var remaining = 479
        for index in sentences.indices {
            let candidate = index.isMultiple(of: 2) ? sentences.count - 1 - index / 2 : index / 2
            let length = sentences[candidate].unicodeScalars.count + (selected.isEmpty ? 0 : 1)
            if length <= remaining {
                selected.append(candidate)
                remaining -= length
            }
            if selected.count == 4 {
                break
            }
        }
        if !selected.isEmpty {
            return selected.sorted().map { sentences[$0] }.joined(separator: " ")
        }
        for quote in cell.quotes {
            let line = "\(quote.participant): \(quote.original)"
            if line.unicodeScalars.count < 480 {
                return line
            }
        }
        if !cell.quotes.isEmpty {
            return "A respondent answered this question. See the verbatim response below."
        }
        return cell.votes.isEmpty ? "A respondent spoke about this question." : "A respondent named a choice."
    }

    private static func voteTally(_ votes: [VoteEvidence], speakers: [String: GuideSpeaker], base: Int?) -> String? {
        guard let base, base > 0, !votes.isEmpty else { return nil }
        var bySeat: [String: String] = [:]
        for vote in votes {
            guard let speaker = respondent(vote.speaker, speakers),
                  let seat = speaker.seatCode, !seat.isEmpty else { return nil }
            if let previous = bySeat[seat], previous != vote.choice {
                return nil
            }
            bySeat[seat] = vote.choice
        }
        guard !bySeat.isEmpty, bySeat.count <= base else { return nil }
        let counts = bySeat.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.keys.sorted().map { "\(counts[$0, default: 0]) of \(base) chose \($0)" }.joined(separator: "; ")
    }

    public mutating func remap(speakers: [String: GuideSpeaker], rosterBase: Int?) {
        for index in cells.indices {
            var cell = cells[index]
            cell.notes.removeAll { note in note.speakers.contains { Self.respondent($0, speakers) == nil } }
            cell.votes.removeAll { Self.respondent($0.speaker, speakers) == nil }
            cell.quotes = cell.quotes.compactMap { quote in
                guard let speaker = Self.respondent(quote.rawSpeaker, speakers) else { return nil }
                var updated = quote
                updated.participant = speaker.participant
                updated.seatCode = speaker.seatCode
                return updated
            }
            let hasEvidence = !cell.notes.isEmpty || !cell.quotes.isEmpty || !cell.votes.isEmpty
            if hasEvidence {
                cell.coverage = !cell.quotes.isEmpty && cell.notes.contains(where: \.substantial) ? "Answered" : "Lightly covered"
                cell.summary = Self.briefSummary(cell)
            } else {
                cell.coverage = "Not covered"
                cell.summary = ""
            }
            let raw = cell.notes.flatMap(\.speakers) + cell.quotes.map(\.rawSpeaker) + cell.votes.map(\.speaker)
            cell.who = Set(raw.compactMap { speakers[$0]?.seatCode }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: " ")
            cell.tally = Self.voteTally(cell.votes, speakers: speakers, base: rosterBase)
            cells[index] = cell
        }
    }

    public mutating func reanchor(_ match: (GuideQuote) -> (startMs: Int, speaker: String)?) {
        for cell in cells.indices {
            for index in cells[cell].quotes.indices {
                var quote = cells[cell].quotes[index]
                let anchor = match(quote)
                quote.locator = Self.locator(anchor?.startMs ?? quote.liveStartMs)
                quote.verification = anchor == nil ? "unverified" : "verified"
                quote.upgradedSpeaker = anchor?.speaker
                cells[cell].quotes[index] = quote
            }
        }
    }
}
