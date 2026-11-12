import Foundation

public struct GuideQuote: Codable, Equatable, Sendable {
    public fileprivate(set) var participant: String
    public fileprivate(set) var locator: String
    public let original: String
    public let english: String
    public let rawSpeaker: String
    public let liveStartMs: Int
    public let turnID: String
    public fileprivate(set) var anchorMs: Int?
    public var offsetMs: Int { anchorMs ?? liveStartMs }

    public var speakerLabel: String {
        if let seatCode, !seatCode.isEmpty { return participant }
        if participant == rawSpeaker || participant == SpeakerLabelMapping.displayLabel(forRawKey: rawSpeaker) { return "Them" }
        return participant
    }
    public fileprivate(set) var seatCode: String?
    public fileprivate(set) var verification: String?
    public fileprivate(set) var upgradedSpeaker: String?

    enum CodingKeys: String, CodingKey {
        case participant, locator, original, english, verification
        case anchorMs = "anchor_ms"
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
    private var furtherQuotes: [GuideQuote]?
    public var orderedQuotes: [GuideQuote] { quotes + (furtherQuotes ?? []) }

    fileprivate mutating func setQuotes(_ values: [GuideQuote]) {
        let ordered = values.sorted { ($0.offsetMs, $0.turnID) < ($1.offsetMs, $1.turnID) }
        quotes = Array(ordered.prefix(4))
        furtherQuotes = ordered.count > 4 ? Array(ordered.dropFirst(4)) : nil
    }

    public func displayCoverage(passed: Bool) -> String {
        coverage == "Not covered" ? (passed ? "Skipped" : "Pending") : coverage
    }
    public fileprivate(set) var tally: String?
    public let score: Double?
    public fileprivate(set) var who = ""

    // The minimal provenance needed to retract a former moderator's contribution
    // and recompute a vote after two speaker IDs are assigned to one seat.
    fileprivate var notes: [NoteEvidence] = []
    fileprivate var votes: [VoteEvidence] = []
    // Preserve withdrawn evidence so correcting a mistaken moderator assignment is reversible.
    fileprivate var withheldQuotes: [GuideQuote]?
    fileprivate var withheldNotes: [NoteEvidence]?
    fileprivate var withheldVotes: [VoteEvidence]?

    fileprivate init(qid: String) {
        self.qid = qid
        score = nil
    }

    private enum CodingKeys: String, CodingKey {
        case qid, coverage, summary, quotes, tally, score, who
        case furtherQuotes = "further_quotes"
        case withheldQuotes = "withheld_quotes"
        case withheldNotes = "withheld_notes"
        case withheldVotes = "withheld_votes"
        case notes = "note_evidence"
        case votes = "vote_evidence"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(qid, forKey: .qid)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(summary, forKey: .summary)
        try c.encode(quotes, forKey: .quotes)
        try c.encodeIfPresent(furtherQuotes, forKey: .furtherQuotes)
        try c.encodeIfPresent(withheldQuotes, forKey: .withheldQuotes)
        try c.encodeIfPresent(withheldNotes, forKey: .withheldNotes)
        try c.encodeIfPresent(withheldVotes, forKey: .withheldVotes)
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

    public struct Position: Codable, Equatable, Sendable {
        public let qid: String
        public let ms: Int
        public let manual: Bool
        public init(qid: String, ms: Int, manual: Bool) {
            self.qid = qid
            self.ms = ms
            self.manual = manual
        }
    }

    public var positions: [Position]?


    enum CodingKeys: String, CodingKey {
        case group, transcript, segment, source, cells, positions
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
        guard raw == "remote" || raw.hasPrefix("remote_"), let label = SpeakerLabelMapping.displayLabel(forRawKey: raw) else { return nil }
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
            var allQuotes = cell.orderedQuotes
            for quote in proposed.quotes {
                guard cited.contains(quote.turn), let original = turn(quote.turn), let speaker = Self.respondent(original.speaker, speakers),
                      !allQuotes.contains(where: { $0.turnID == original.id }) else { continue }
                allQuotes.append(GuideQuote(participant: speaker.participant, locator: Self.locator(original.startMs),
                                              original: original.text, english: quote.english, rawSpeaker: original.speaker,
                                              liveStartMs: original.startMs, turnID: original.id, seatCode: speaker.seatCode))
            }
            cell.setQuotes(allQuotes)
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
            let notes = cell.notes + (cell.withheldNotes ?? [])
            let votes = cell.votes + (cell.withheldVotes ?? [])
            let quotes = cell.orderedQuotes + (cell.withheldQuotes ?? [])
            cell.notes = notes.filter { note in note.speakers.allSatisfy { Self.respondent($0, speakers) != nil } }
            let hiddenNotes = notes.filter { note in note.speakers.contains { Self.respondent($0, speakers) == nil } }
            cell.withheldNotes = hiddenNotes.isEmpty ? nil : hiddenNotes
            cell.votes = votes.filter { Self.respondent($0.speaker, speakers) != nil }
            let hiddenVotes = votes.filter { Self.respondent($0.speaker, speakers) == nil }
            cell.withheldVotes = hiddenVotes.isEmpty ? nil : hiddenVotes
            var hiddenQuotes: [GuideQuote] = []
            cell.setQuotes(quotes.compactMap { quote in
                guard let speaker = Self.respondent(quote.rawSpeaker, speakers) else {
                    hiddenQuotes.append(quote)
                    return nil
                }
                var updated = quote
                updated.participant = speaker.participant
                updated.seatCode = speaker.seatCode
                return updated
            })
            cell.withheldQuotes = hiddenQuotes.isEmpty ? nil : hiddenQuotes
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
        for index in cells.indices {
            func anchored(_ original: GuideQuote) -> GuideQuote {
                var quote = original
                let anchor = match(quote)
                quote.anchorMs = anchor?.startMs
                quote.locator = Self.locator(quote.offsetMs)
                quote.verification = anchor == nil ? "unverified" : "verified"
                quote.upgradedSpeaker = anchor?.speaker
                return quote
            }
            cells[index].setQuotes(cells[index].orderedQuotes.map(anchored))
            cells[index].withheldQuotes = cells[index].withheldQuotes?.map(anchored)
        }
    }

    /// Reconcile evidence by turn identity. A summary spanning two new
    /// questions cannot support either one, but both verbatims remain available.
    public mutating func refile(speakers: [String: GuideSpeaker], rosterBase: Int?,
                                questionAt: (Int) -> String?) {
        let indexes = Dictionary(uniqueKeysWithValues: cells.enumerated().map { ($1.qid, $0) })
        let byTurn = Dictionary(cells.flatMap { $0.orderedQuotes + ($0.withheldQuotes ?? []) }.map { ($0.turnID, $0.offsetMs) },
                                uniquingKeysWith: { first, _ in first })
        func destination(_ turn: String, source: Int) -> Int {
            let timestamp = byTurn[turn] ?? turn.split(separator: "@").last?.split(separator: "#").first.flatMap { Int($0) }
            return timestamp.flatMap(questionAt).flatMap { indexes[$0] } ?? source
        }
        let previous = cells
        var quotes = Array(repeating: [GuideQuote](), count: cells.count)
        var seen = Set<String>()
        for index in cells.indices {
            cells[index].notes = []
            cells[index].votes = []
            cells[index].withheldQuotes = nil
            cells[index].withheldNotes = nil
            cells[index].withheldVotes = nil
        }
        for (source, cell) in previous.enumerated() {
            for quote in cell.orderedQuotes + (cell.withheldQuotes ?? []) where seen.insert(quote.turnID).inserted {
                quotes[destination(quote.turnID, source: source)].append(quote)
            }
            for note in cell.notes + (cell.withheldNotes ?? []) {
                let targets = Set(note.turnIDs.map { destination($0, source: source) })
                if targets.count == 1, let target = targets.first { cells[target].notes.append(note) }
            }
            for vote in cell.votes + (cell.withheldVotes ?? []) { cells[destination(vote.turn, source: source)].votes.append(vote) }
        }
        for index in cells.indices { cells[index].setQuotes(quotes[index]) }
        remap(speakers: speakers, rosterBase: rosterBase)
    }
}
