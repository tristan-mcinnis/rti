import Foundation
import RTICore

/// The only durable quote text is copied from a settled original-language turn.
struct ResearchQuote: Codable, Equatable, Identifiable, Sendable {
    struct Attribution: Codable, Equatable, Sendable {
        let rawSpeaker: String
        let label: String
        let leg: String
        let confidence: String
        let seat: String?
        let segment: String?
        let moderator: Bool
    }

    let sessionID: String
    let turnID: String
    let group: String?
    let offsetMs: Int
    let original: String
    let speaker: Attribution
    var guideQuestionAtCapture: String?
    var questionID: String?
    var markerID: String?
    var markerLabel: String?
    var showEventID: String?
    var shownItemIDs: [String]?
    var shownCodes: [String]?
    var packageRevision: String?
    var revealRecorded: Bool
    var mentionedCodes: [String]?
    var upgradedOffsetMs: Int?
    var anchorNeedsReview: Bool?
    var id: String {
        sessionID + "/" + turnID
    }
}

/// What a code means (schema 2, 2026-11-13). A codebook is a list of
/// meanings, never of people: `person` and `org` (and the old catch-all
/// `concept`) exist only so schema 1 archives still load. A pass never
/// creates them, and `person` and `org` cards are never shown as codes.
enum ResearchCardType: String, CaseIterable, Codable, Sendable {
    case theme, need
    case emicTerm = "emic_term"
    case ritual, trigger, channel, barrier, brand
    case stimulusReaction = "stimulus_reaction"
    case tension, hypothesis, vote
    case clientQuestion = "client_question"
    case concept, person, org

    /// The types a pass may create, in prompt order.
    static let codes: [Self] = [.theme, .need, .emicTerm, .ritual, .trigger, .channel, .barrier, .brand,
                                .stimulusReaction, .tension, .hypothesis, .vote, .clientQuestion]

    /// False for the schema 1 people and organisation cards.
    var isCode: Bool {
        self != .person && self != .org
    }

    /// Theme-like codes: the plain meanings that show as chips.
    var isTheme: Bool {
        [.theme, .need, .emicTerm, .ritual, .trigger, .channel, .barrier, .stimulusReaction, .concept].contains(self)
    }

    var label: String {
        switch self {
        case .theme, .concept: "theme"
        case .need: "need"
        case .emicTerm: "emic term"
        case .ritual: "ritual"
        case .trigger: "trigger"
        case .channel: "channel"
        case .barrier: "barrier"
        case .brand: "brand"
        case .stimulusReaction: "stimulus reaction"
        case .tension: "tension"
        case .hypothesis: "hypothesis"
        case .vote: "vote"
        case .clientQuestion: "client question"
        case .person: "person"
        case .org: "organisation"
        }
    }

    /// A lenient read of a model's or a seed file's type word: `emic term`,
    /// `emic-term` and `emicTerm` all mean `emic_term`. `concept` reads as
    /// `theme`. Returns nil for an unknown word.
    init?(loose raw: String) {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if folded == "concept" {
            self = .theme
        } else if folded == "organisation" || folded == "organization" {
            self = .org
        } else if let value = Self(rawValue: folded) {
            self = value
        } else {
            return nil
        }
    }
}

enum ResearchValence: String, CaseIterable, Codable, Sendable { case positive, negative, mixed, neutral }

/// How a quote came: unprompted, after a closed or leading question, or as
/// agreement with someone else.
enum ResearchStrength: String, Codable, Sendable { case spontaneous, prompted, agreement }

/// Where a code started: in the respondents' own words, after a closed or
/// leading question, or with the moderator saying it first.
enum ResearchProvenance: String, Codable, Sendable {
    case spontaneous, prompted
    case moderatorIntroduced = "moderator_introduced"

    var label: String {
        switch self {
        case .spontaneous: "spontaneous"
        case .prompted: "prompted"
        case .moderatorIntroduced: "moderator introduced"
        }
    }
}

/// A hypothesis quote counts for it or against it.
enum ResearchStance: String, Codable, Sendable {
    case support = "for"
    case against
}

enum ResearchQuestionStatus: String, Codable, Sendable {
    case open
    case partly = "partly answered"
    case answered

    init?(loose raw: String) {
        let folded = raw.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if folded.hasPrefix("partly") || folded.hasPrefix("partially") {
            self = .partly
        } else if let value = Self(rawValue: folded) {
            self = value
        } else {
            return nil
        }
    }
}

/// One line of a vote card: a choice and its count, from a moderator's
/// spoken tally of a show of hands, a sticker vote or an explicit pick.
struct ResearchVote: Codable, Equatable, Sendable {
    let sessionID: String
    let choice: String
    var count: Int
    var source: String
    var turnID: String
    var offsetMs: Int
}

struct ResearchEntry: Codable, Equatable, Identifiable, Sendable {
    let point: String
    var evidence: ResearchQuote
    let valence: ResearchValence
    let inferredName: String?
    /// The exact words that carry the code, a substring of `evidence.original`.
    var excerpt: String?
    var strength: ResearchStrength?
    /// The words may be a speech-recognition error; `point` gives the likely meaning.
    var asrDoubt: Bool?
    /// Hypothesis entries only.
    var stance: ResearchStance?
    /// Tension entries only: the other side, from a different turn.
    var counter: ResearchQuote?
    var id: String {
        evidence.id
    }

    /// The words to show for this quote: the excerpt when there is one.
    var words: String {
        excerpt ?? evidence.original
    }
}

struct ResearchCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The canonical name. For a theme, need, tension, barrier or emic term
    /// this is the respondents' own Chinese words; `gloss` is the English.
    var name: String
    var aliases: [String]
    let type: ResearchCardType
    enum Origin: String, Codable, Sendable { case seeded, emerged }
    var origin: Origin
    var seeded: Bool {
        get { origin == .seeded }
        set { origin = newValue ? .seeded : .emerged }
    }

    var pinned: Bool
    var entries: [ResearchEntry]
    var gloss: String?
    var qids: [String]?
    var provenance: ResearchProvenance?
    var votes: [ResearchVote]?
    var questionStatus: ResearchQuestionStatus?
    /// The client's own brand or product, from the brief.
    var clientBrand: Bool?

    var summary: String {
        var seen: Set<String> = []
        return entries.reversed().compactMap { seen.insert($0.point).inserted ? $0.point : nil }
            .prefix(3).reversed().joined(separator: " ")
    }

    /// Quotes, never people: a tension entry cites two.
    var quoteCount: Int {
        entries.count + entries.filter { $0.counter != nil }.count
    }

    /// `quoteCount` for one session, without copying the card.
    func quoteCount(in sessionID: String?) -> Int {
        guard let sessionID else { return quoteCount }
        return entries.reduce(0) { total, entry in
            entry.evidence.sessionID == sessionID ? total + (entry.counter == nil ? 1 : 2) : total
        }
    }

    var support: (for: Int, against: Int) {
        (entries.filter { $0.stance == .support }.count, entries.filter { $0.stance == .against }.count)
    }
}

extension ResearchCard {
    /// The card trimmed to one session's quotes and votes.
    func session(_ sessionID: String?) -> ResearchCard {
        guard let sessionID else { return self }
        var card = self
        card.entries = entries.filter { $0.evidence.sessionID == sessionID }
        card.votes = votes?.filter { $0.sessionID == sessionID }
        return card
    }

    var hasEvidence: Bool {
        !entries.isEmpty || !(votes ?? []).isEmpty
    }
}

/// A model's reply to a codebook pass. Decoding is lenient: a bad field
/// drops that field, a bad entry drops that entry, never the whole reply.
struct ResearchProposal: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var code: String?
        var nameZh: String?
        var nameEn: String?
        var type: ResearchCardType?
        var aliases: [String] = []
        var turnID: String
        var counterTurnID: String?
        var qid: String?
        var quote: String?
        var emic: String?
        var point: String
        var valence: ResearchValence = .neutral
        var strength: ResearchStrength?
        var stance: ResearchStance?
        var choice: String?
        var count: Int?
        var source: String?
        var asrDoubt = false

        init(code: String? = nil, nameZh: String? = nil, nameEn: String? = nil, type: ResearchCardType?,
             aliases: [String] = [], turnID: String, counterTurnID: String? = nil, qid: String? = nil,
             quote: String? = nil, emic: String? = nil, point: String, valence: ResearchValence = .neutral,
             strength: ResearchStrength? = nil, stance: ResearchStance? = nil, choice: String? = nil,
             count: Int? = nil, source: String? = nil, asrDoubt: Bool = false)
        {
            self.code = code; self.nameZh = nameZh; self.nameEn = nameEn; self.type = type
            self.aliases = aliases; self.turnID = turnID; self.counterTurnID = counterTurnID; self.qid = qid
            self.quote = quote; self.emic = emic; self.point = point; self.valence = valence
            self.strength = strength; self.stance = stance; self.choice = choice; self.count = count
            self.source = source; self.asrDoubt = asrDoubt
        }

        /// The schema 1 shape: one canonical name.
        init(name: String, aliases: [String]?, type: ResearchCardType, turnID: String, point: String, valence: ResearchValence) {
            self.init(nameEn: name, type: type, aliases: aliases ?? [], turnID: turnID, point: point, valence: valence)
        }

        private enum CodingKeys: String, CodingKey {
            case code, name, type, aliases, turnID, counterTurnID, qid, quote, emic, point, valence, strength, stance
            case choice, count, source, asrDoubt
            case nameZh = "name_zh", nameEn = "name_en"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let turnID = c.looseString(.turnID) else {
                throw DecodingError.keyNotFound(CodingKeys.turnID, .init(codingPath: decoder.codingPath, debugDescription: "An entry needs a turn."))
            }
            self.turnID = turnID
            code = c.looseString(.code)
            nameZh = c.looseString(.nameZh)
            nameEn = c.looseString(.nameEn) ?? c.looseString(.name)
            type = c.looseString(.type).flatMap(ResearchCardType.init(loose:))
            aliases = c.lossyStrings(.aliases)
            counterTurnID = c.looseString(.counterTurnID)
            qid = c.looseString(.qid)
            quote = c.looseString(.quote)
            emic = c.looseString(.emic)
            point = c.looseString(.point) ?? ""
            valence = c.looseString(.valence).flatMap { ResearchValence(rawValue: $0.lowercased()) } ?? .neutral
            strength = c.looseString(.strength).flatMap { ResearchStrength(rawValue: $0.lowercased()) }
            stance = c.looseString(.stance).flatMap { ResearchStance(rawValue: $0.lowercased()) }
            choice = c.looseString(.choice)
            count = c.looseInt(.count)
            source = c.looseString(.source)
            asrDoubt = (try? c.decodeIfPresent(Bool.self, forKey: .asrDoubt)) ?? false
        }
    }

    struct NameHint: Decodable, Sendable {
        let moderatorTurnID: String
        let respondentTurnID: String
        let name: String
    }

    let entries: [Item]
    let names: [NameHint]?

    init(entries: [Item], names: [NameHint]?) {
        self.entries = entries; self.names = names
    }

    private enum CodingKeys: String, CodingKey { case entries, names }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = c.lossyArray(Item.self, .entries)
        let names = c.lossyArray(NameHint.self, .names)
        self.names = names.isEmpty ? nil : names
    }
}

/// The ten-minute synthesis pass's reply: merges, tensions across minutes,
/// hypotheses with quotes for and against, and client question status.
struct ResearchSynthesis: Decodable, Sendable {
    struct Merge: Decodable, Sendable {
        let from: String
        let into: String
    }

    struct Tension: Decodable, Sendable {
        var nameZh: String?
        var nameEn: String?
        var turnID: String
        var counterTurnID: String
        var point: String?
        private enum CodingKeys: String, CodingKey {
            case turnID, counterTurnID, point
            case nameZh = "name_zh", nameEn = "name_en"
        }

        init(nameZh: String?, nameEn: String?, turnID: String, counterTurnID: String, point: String?) {
            self.nameZh = nameZh; self.nameEn = nameEn; self.turnID = turnID; self.counterTurnID = counterTurnID; self.point = point
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let turn = c.looseString(.turnID), let counter = c.looseString(.counterTurnID) else {
                throw DecodingError.keyNotFound(CodingKeys.turnID, .init(codingPath: decoder.codingPath, debugDescription: "A tension needs two turns."))
            }
            self.init(nameZh: c.looseString(.nameZh), nameEn: c.looseString(.nameEn), turnID: turn, counterTurnID: counter, point: c.looseString(.point))
        }
    }

    struct Hypothesis: Decodable, Sendable {
        var code: String?
        var nameZh: String?
        var nameEn: String?
        var support: [String]
        var against: [String]
        var point: String?
        private enum CodingKeys: String, CodingKey {
            case code, against, point
            case support = "for", nameZh = "name_zh", nameEn = "name_en"
        }

        init(code: String?, nameZh: String?, nameEn: String?, support: [String], against: [String], point: String?) {
            self.code = code; self.nameZh = nameZh; self.nameEn = nameEn; self.support = support; self.against = against; self.point = point
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(code: c.looseString(.code), nameZh: c.looseString(.nameZh), nameEn: c.looseString(.nameEn),
                      support: c.lossyStrings(.support), against: c.lossyStrings(.against), point: c.looseString(.point))
        }
    }

    struct ClientQuestion: Decodable, Sendable {
        var code: String
        var status: ResearchQuestionStatus?
        var turnIDs: [String]
        private enum CodingKeys: String, CodingKey { case code, status, turnIDs }

        init(code: String, status: ResearchQuestionStatus?, turnIDs: [String]) {
            self.code = code; self.status = status; self.turnIDs = turnIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let code = c.looseString(.code) else {
                throw DecodingError.keyNotFound(CodingKeys.code, .init(codingPath: decoder.codingPath, debugDescription: "A client question needs a code."))
            }
            self.init(code: code, status: c.looseString(.status).flatMap(ResearchQuestionStatus.init(loose:)), turnIDs: c.lossyStrings(.turnIDs))
        }
    }

    var merges: [Merge] = []
    var tensions: [Tension] = []
    var hypotheses: [Hypothesis] = []
    var clientQuestions: [ClientQuestion] = []

    init(merges: [Merge] = [], tensions: [Tension] = [], hypotheses: [Hypothesis] = [], clientQuestions: [ClientQuestion] = []) {
        self.merges = merges; self.tensions = tensions; self.hypotheses = hypotheses; self.clientQuestions = clientQuestions
    }

    private enum CodingKeys: String, CodingKey { case merges, tensions, hypotheses, clientQuestions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        merges = c.lossyArray(Merge.self, .merges)
        tensions = c.lossyArray(Tension.self, .tensions)
        hypotheses = c.lossyArray(Hypothesis.self, .hypotheses)
        clientQuestions = c.lossyArray(ClientQuestion.self, .clientQuestions)
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func looseString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        }
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    func looseInt(_ key: Key) -> Int? {
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        return looseString(key).flatMap { Int($0.filter(\.isNumber)) }
    }

    func lossyArray<Value: Decodable>(_: Value.Type, _ key: Key) -> [Value] {
        (try? decodeIfPresent([Lossy<Value>].self, forKey: key))?.compactMap(\.value) ?? []
    }

    func lossyStrings(_ key: Key) -> [String] {
        if let one = looseString(key) {
            return [one]
        }
        return lossyArray(String.self, key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct ResearchCodebook: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let group: String?
        let startedAt: Date
        let folder: String
        var consumed: Set<String> = []
        var endMs = 0
        var incomplete = false
    }

    /// Schema 2 added meanings (types, gloss, votes, tensions, hypotheses,
    /// client questions). Schema 1 files still load.
    static let currentSchema = 2
    var schemaVersion = currentSchema
    var projectDirectory: String?
    var projectMergePending: Bool?
    var sessions: [Session] = []
    var cards: [ResearchCard] = []
    var suppressed: Set<String> = []
    var redirects: [String: UUID] = [:]
    /// The study objective from a seed line `objective | …`.
    var objective: String?

    /// About 40 codes per session after merging (1.4). Votes are records
    /// and still land past the cap.
    static let sessionCodeCap = 40
    /// New non-brand codes per pass (rule 4).
    static let newCodesPerPass = 3
    static let newBrandsPerPass = 8

    static func key(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func spellings(_ name: String, aliases: [String]) -> Set<String> {
        let parts = name.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .components(separatedBy: CharacterSet(charactersIn: "()"))
        return Set(([name] + aliases + parts).map(key).filter { !$0.isEmpty })
    }

    static func spellings(_ card: ResearchCard) -> Set<String> {
        spellings(card.name, aliases: card.aliases + [card.gloss].compactMap(\.self))
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400 ... 0x9FFF).contains($0.value) || (0xF900 ... 0xFAFF).contains($0.value) }
    }

    /// Rule 11: a turn-ID prefix or a role word is never a code name.
    static func isSpeakerLabel(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["主持人", "受访者", "被访者", "参与者", "发言人", "我"].contains(folded) {
            return true
        }
        return folded.wholeMatch(of: /(self|me|you|them|remote|room|speaker|moderator|respondent|participant|interviewer|interviewee)([ _#-]?[0-9]+)?/) != nil
    }

    /// Code cards that share a spelling. Schema 1 person and org cards
    /// still sit in old project books but are hidden everywhere, so a code
    /// never resolves to one (its quotes would vanish from view).
    private func matches(_ keys: Set<String>) -> [Int] {
        cards.indices.filter { cards[$0].type.isCode && !keys.isDisjoint(with: Self.spellings(cards[$0])) }
    }

    /// Votes, tensions and hypotheses have their own entry shape, so an item
    /// of one of those types only files into a card of the same type, and
    /// no other item files into one of them. Rule 2 rests on this: the
    /// moderator's tally turn is filed only as a vote, never as a quote.
    static func canFile(_ type: ResearchCardType, into target: ResearchCardType) -> Bool {
        let shaped: Set<ResearchCardType> = [.vote, .tension, .hypothesis]
        guard target.isCode else { return false }
        return shaped.contains(type) || shaped.contains(target) ? type == target : true
    }

    private func index(of id: UUID) -> Int? {
        let target = redirects[id.uuidString] ?? id
        return cards.firstIndex { $0.id == target }
    }

    mutating func seed(_ name: String, type: ResearchCardType = .theme, pinned: Bool = false, client: Bool = false) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Self.spellings(clean, aliases: [])
        guard type.isCode, !keys.isEmpty, keys.isDisjoint(with: suppressed) else { return }
        let found = matches(keys)
        if found.count == 1 {
            cards[found[0]].seeded = true
            if pinned { cards[found[0]].pinned = true }
            if client { cards[found[0]].clientBrand = true }
        }
        if found.isEmpty {
            cards.append(ResearchCard(id: UUID(), name: clean, aliases: [], type: type, origin: .seeded, pinned: pinned, entries: [],
                                      questionStatus: type == .clientQuestion ? .open : nil, clientBrand: client ? true : nil))
        }
    }

    /// A card's tallies from one group's sessions (all of them when no
    /// group is chosen). A group is `group ?? id`, as the Codebook tab names it.
    static func votes(_ card: ResearchCard, group: String?, sessions: [Session]) -> [ResearchVote] {
        guard let group else { return card.votes ?? [] }
        let ids = Set(sessions.filter { ($0.group ?? $0.id) == group }.map(\.id))
        return (card.votes ?? []).filter { ids.contains($0.sessionID) }
    }

    /// Every code's quotes in one session.
    func quoteCount(in sessionID: String) -> Int {
        cards.reduce(0) { $0 + ($1.type.isCode ? $1.quoteCount(in: sessionID) : 0) }
    }

    /// Codes with a quote or a vote in one session.
    func codeCount(in sessionID: String) -> Int {
        cards.filter { $0.type.isCode && $0.session(sessionID).hasEvidence }.count
    }

    /// Every cited quote in one session, by turn ID, so a tension can cite
    /// a turn from an earlier pass.
    func quotes(in sessionID: String) -> [String: ResearchQuote] {
        var found: [String: ResearchQuote] = [:]
        for entry in cards.flatMap(\.entries) where entry.evidence.sessionID == sessionID {
            found[entry.evidence.turnID] = entry.evidence
            if let counter = entry.counter { found[counter.turnID] = counter }
        }
        return found
    }

    // MARK: - A codebook pass

    /// File one pass's entries. The prompt asks for the rules; this enforces
    /// the ones code can check: moderator lines are never evidence (a vote
    /// may cite a tally), no person, organisation or speaker-label codes,
    /// merge before create, at most three new non-brand codes a pass, about
    /// 40 codes a session, a tension cites two different turns.
    mutating func apply(_ proposal: ResearchProposal, sources: [ResearchQuote], codes: [String: UUID] = [:], forbidden: Set<String> = []) {
        let turns = Dictionary(sources.map { ($0.turnID, $0) }, uniquingKeysWith: { first, _ in first })
        var hints: [String: String] = [:]
        for hint in proposal.names ?? [] {
            let name = hint.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let question = turns[hint.moderatorTurnID], question.speaker.moderator,
                  question.original.contains(name), let reply = turns[hint.respondentTurnID], !reply.speaker.moderator,
                  reply.offsetMs >= question.offsetMs, reply.offsetMs - question.offsetMs <= 30000,
                  !sources.contains(where: { $0.offsetMs > question.offsetMs && $0.offsetMs < reply.offsetMs && !$0.speaker.moderator }) else { continue }
            hints[reply.turnID] = name
        }
        let sessionID = sources.first?.sessionID
        let earlier = sessionID.map(quotes(in:)) ?? [:]
        let forbiddenKeys = Set(forbidden.map(Self.key))
        let brandKeys = cards.filter { $0.type == .brand }.flatMap { Self.spellings($0) }.filter { $0.count >= 2 }

        // Resolve every item first, so a new code can count its quotes.
        struct Planned {
            let item: ResearchProposal.Item
            let type: ResearchCardType
            let name: String
            let gloss: String?
            let keys: Set<String>
            /// The name and gloss alone, without the model's aliases.
            let nameKeys: Set<String>
            let quote: ResearchQuote
            let counter: ResearchQuote?
            let existing: Int?
        }
        var planned: [Planned] = []
        for item in proposal.entries {
            guard var type = item.type, type.isCode else { continue }
            if type == .concept { type = .theme }
            guard let quote = turns[item.turnID], type == .vote || !quote.speaker.moderator else { continue }
            var counter: ResearchQuote?
            if type == .tension {
                guard let other = item.counterTurnID.flatMap({ turns[$0] ?? earlier[$0] }), other.turnID != quote.turnID,
                      !other.speaker.moderator else { continue }
                counter = other
            }
            let codeID = item.code.flatMap { codes[$0] }
            var zh = item.nameZh, en = item.nameEn
            if zh == nil, let emic = item.emic, Self.containsCJK(emic), quote.original.contains(emic) {
                zh = emic // rule 6: keep the emic phrase
            }
            if zh == nil, let name = en, Self.containsCJK(name) {
                zh = name; en = nil
            }
            let existingByID = codeID.flatMap(index(of:))
            guard let name = zh ?? en ?? existingByID.map({ cards[$0].name }) else { continue }
            let gloss = zh != nil && en != nil && en != zh ? en : nil
            guard !Self.isSpeakerLabel(name), !forbiddenKeys.contains(Self.key(name)) else { continue }
            let aliases = item.aliases.filter { !$0.isEmpty && !Self.isSpeakerLabel($0) }
            let nameKeys = Self.spellings(name, aliases: [gloss].compactMap(\.self))
            let keys = Self.spellings(name, aliases: aliases + [gloss].compactMap(\.self))
            guard keys.isDisjoint(with: suppressed) else { continue }
            let found = matches(keys)
            let existing: Int?
            if let byID = existingByID {
                // A brand never absorbs another brand's spelling (rule 5).
                guard found.allSatisfy({ $0 == byID }) else { continue }
                existing = byID
            } else {
                guard found.count <= 1 else { continue }
                existing = found.first
            }
            // Rule 2: a moderator line lands only on a vote card, as a tally.
            if let existing, !Self.canFile(type, into: cards[existing].type) { continue }
            planned.append(Planned(item: item, type: type, name: name, gloss: gloss, keys: keys, nameKeys: nameKeys, quote: quote,
                                   counter: counter, existing: existing))
        }

        // Quotes per new code in this pass (rule 4).
        var newQuotes: [String: Set<String>] = [:]
        for plan in planned where plan.existing == nil {
            newQuotes[Self.key(plan.name), default: []].insert(plan.quote.turnID)
            if let counter = plan.counter { newQuotes[Self.key(plan.name), default: []].insert(counter.turnID) }
        }
        var createdCodes = 0, createdBrands = 0
        var sessionCodes = sessionID.map(codeCount(in:)) ?? 0
        var created: [String: Int] = [:]

        for plan in planned {
            let index: Int
            if let existing = plan.existing {
                index = existing
            } else if let made = created[Self.key(plan.name)] ?? matches(plan.type == .brand ? plan.nameKeys : plan.keys).first {
                guard Self.canFile(plan.type, into: cards[made].type) else { continue }
                index = made
            } else {
                let quoteCount = newQuotes[Self.key(plan.name)]?.count ?? 0
                let namesBrand = !plan.quote.mentionedCodes.isNilOrEmpty
                    || brandKeys.contains { Self.key(plan.quote.original).contains($0) }
                let recordType = [.vote, .clientQuestion, .hypothesis].contains(plan.type)
                let qualifies = plan.type == .brand || plan.type == .barrier || recordType || quoteCount >= 2 || namesBrand
                guard qualifies, plan.type == .vote || sessionCodes < Self.sessionCodeCap else { continue }
                if plan.type == .brand {
                    guard createdBrands < Self.newBrandsPerPass else { continue }
                    createdBrands += 1
                } else if plan.type != .vote {
                    guard createdCodes < Self.newCodesPerPass else { continue }
                    createdCodes += 1
                }
                index = cards.count
                cards.append(ResearchCard(id: UUID(), name: plan.name, aliases: [], type: plan.type, origin: .emerged, pinned: false, entries: [],
                                          gloss: plan.gloss, provenance: Self.provenance(of: plan.quote, names: plan.keys, strength: plan.item.strength, in: sources),
                                          questionStatus: plan.type == .clientQuestion ? .open : nil))
                created[Self.key(plan.name)] = index
                sessionCodes += 1
            }
            file(plan.item, name: plan.name, gloss: plan.gloss, quote: plan.quote, counter: plan.counter, hint: hints[plan.quote.turnID], into: index)
        }
    }

    /// Rule 9: moderator first, then prompted, else spontaneous.
    private static func provenance(of quote: ResearchQuote, names: Set<String>, strength: ResearchStrength?, in sources: [ResearchQuote]) -> ResearchProvenance {
        let introduced = sources.contains { source in
            guard source.speaker.moderator, source.offsetMs <= quote.offsetMs else { return false }
            let words = key(source.original)
            return names.contains { $0.count >= 2 && words.contains($0) }
        }
        if introduced { return .moderatorIntroduced }
        return strength == .prompted ? .prompted : .spontaneous
    }

    private mutating func file(_ item: ResearchProposal.Item, name: String, gloss: String?, quote: ResearchQuote, counter: ResearchQuote?,
                               hint: String?, into index: Int)
    {
        let card = cards[index]
        // Rule 2, checked again where it bites: a moderator line is never a quote.
        guard card.type == .vote || !quote.speaker.moderator else { return }
        let spellings = card.type == .brand ? [name, item.nameEn, item.nameZh].compactMap(\.self) + item.aliases : item.aliases
        // A brand never takes another brand's spelling as an alias (rule 5).
        let otherBrands: Set<String> = card.type == .brand
            ? Set(cards.indices.filter { $0 != index && cards[$0].type == .brand }.flatMap { Self.spellings(cards[$0]) }) : []
        for alias in spellings where !alias.isEmpty && alias != cards[index].name && alias != cards[index].gloss && !cards[index].aliases.contains(alias)
            && !Self.isSpeakerLabel(alias) && !otherBrands.contains(Self.key(alias))
        {
            cards[index].aliases.append(alias)
        }
        if cards[index].gloss == nil, let gloss, gloss != cards[index].name {
            cards[index].gloss = gloss
        }
        for qid in [item.qid, quote.questionID].compactMap(\.self) where qid.wholeMatch(of: /S[0-9]+Q[0-9]+/) != nil {
            if !(cards[index].qids ?? []).contains(qid) { cards[index].qids = (cards[index].qids ?? []) + [qid] }
        }
        if card.type == .vote {
            guard let choice = item.choice?.trimmingCharacters(in: .whitespacesAndNewlines), !choice.isEmpty,
                  let count = item.count, (0 ... 999).contains(count) else { return }
            var votes = cards[index].votes ?? []
            let tally = ResearchVote(sessionID: quote.sessionID, choice: choice, count: count, source: item.source ?? "moderator_tally",
                                     turnID: quote.turnID, offsetMs: quote.offsetMs)
            if let at = votes.firstIndex(where: { $0.sessionID == quote.sessionID && Self.key($0.choice) == Self.key(choice) }) {
                if votes[at].offsetMs <= quote.offsetMs { votes[at] = tally }
            } else {
                votes.append(tally)
            }
            cards[index].votes = votes
            return
        }
        let point = item.point.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !point.isEmpty, !cards[index].entries.contains(where: { $0.id == quote.id }) else { return }
        let excerpt = item.quote.flatMap { words -> String? in
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”「」'")))
            return !trimmed.isEmpty && trimmed.count <= 80 && trimmed != quote.original && quote.original.contains(trimmed) ? trimmed : nil
        }
        var stance = item.stance
        if card.type == .hypothesis, stance == nil {
            stance = item.valence == .positive ? .support : item.valence == .negative ? .against : nil
        }
        cards[index].entries.append(ResearchEntry(point: point, evidence: quote, valence: item.valence, inferredName: hint, excerpt: excerpt,
                                                  strength: item.strength, asrDoubt: item.asrDoubt ? true : nil,
                                                  stance: card.type == .hypothesis ? stance : nil, counter: counter))
        if card.type == .clientQuestion, cards[index].questionStatus == nil || cards[index].questionStatus == .open {
            cards[index].questionStatus = .partly
        }
    }

    // MARK: - The synthesis pass

    static let mergesPerSynthesis = 5
    static let tensionsPerSynthesis = 3
    static let hypothesesPerSynthesis = 2

    /// Apply a synthesis reply. It cites only quotes already in the book:
    /// it never adds new words, only new links between them.
    mutating func apply(_ synthesis: ResearchSynthesis, sessionID: String, codes: [String: UUID]) {
        var merged = 0
        for merge in synthesis.merges where merged < Self.mergesPerSynthesis {
            guard let from = codes[merge.from].flatMap(index(of:)), let into = codes[merge.into].flatMap(index(of:)), from != into else { continue }
            let a = cards[from], b = cards[into]
            let records: Set<ResearchCardType> = [.brand, .vote, .clientQuestion, .tension, .hypothesis]
            // Never merge two brands (rule 5), never a pinned card, never a record into a different type.
            guard !(a.type == .brand && b.type == .brand), !a.pinned, a.type == b.type || (!records.contains(a.type) && !records.contains(b.type)) else { continue }
            edit(.merge(a.id, into: b.id))
            merged += 1
        }
        let quotes = quotes(in: sessionID).filter { !$0.value.speaker.moderator }
        var tensions = 0
        for tension in synthesis.tensions where tensions < Self.tensionsPerSynthesis {
            guard let one = quotes[tension.turnID], let two = quotes[tension.counterTurnID], one.turnID != two.turnID,
                  abs(one.offsetMs - two.offsetMs) >= 60000 else { continue }
            let (first, second) = one.offsetMs <= two.offsetMs ? (one, two) : (two, one)
            let item = ResearchProposal.Item(nameZh: tension.nameZh, nameEn: tension.nameEn, type: .tension, turnID: second.turnID,
                                             counterTurnID: first.turnID, point: tension.point ?? "Two quotes pull in different directions.",
                                             valence: .mixed)
            guard let index = codeIndex(for: item, type: .tension, sessionID: sessionID, codes: codes) else { continue }
            if cards[index].entries.contains(where: { $0.id == second.id && $0.counter?.turnID == first.turnID }) { continue }
            file(item, name: cards[index].name, gloss: nil, quote: second, counter: first, hint: nil, into: index)
            tensions += 1
        }
        var newHypotheses = 0
        for hypothesis in synthesis.hypotheses {
            let item = ResearchProposal.Item(code: hypothesis.code, nameZh: hypothesis.nameZh, nameEn: hypothesis.nameEn, type: .hypothesis,
                                             turnID: "", point: hypothesis.point ?? "")
            let before = cards.count
            guard hypothesis.code != nil || newHypotheses < Self.hypothesesPerSynthesis,
                  let index = codeIndex(for: item, type: .hypothesis, sessionID: sessionID, codes: codes) else { continue }
            if cards.count > before { newHypotheses += 1 }
            for (turnIDs, stance) in [(hypothesis.support, ResearchStance.support), (hypothesis.against, .against)] {
                for turn in turnIDs.prefix(6) {
                    guard let quote = quotes[turn], !cards[index].entries.contains(where: { $0.id == quote.id }) else { continue }
                    let point = hypothesis.point ?? (stance == .support ? "Supports this hypothesis." : "Counts against this hypothesis.")
                    cards[index].entries.append(ResearchEntry(point: point, evidence: quote, valence: stance == .support ? .positive : .negative,
                                                              inferredName: nil, stance: stance))
                }
            }
        }
        for question in synthesis.clientQuestions {
            guard let index = codes[question.code].flatMap(index(of:)), cards[index].type == .clientQuestion else { continue }
            if let status = question.status { cards[index].questionStatus = status }
            for turn in question.turnIDs.prefix(2) {
                guard let quote = quotes[turn], !cards[index].entries.contains(where: { $0.id == quote.id }) else { continue }
                cards[index].entries.append(ResearchEntry(point: "Speaks to this client question.", evidence: quote, valence: .neutral, inferredName: nil))
            }
        }
    }

    /// The card a synthesis item names: by code id, else by spelling, else a
    /// new emerged card within the session cap.
    private mutating func codeIndex(for item: ResearchProposal.Item, type: ResearchCardType, sessionID: String, codes: [String: UUID]) -> Int? {
        if let id = item.code.flatMap({ codes[$0] }) {
            guard let found = index(of: id), cards[found].type == type else { return nil }
            return found
        }
        var zh = item.nameZh, en = item.nameEn
        if zh == nil, let name = en, Self.containsCJK(name) { zh = name; en = nil }
        guard let name = zh ?? en, !Self.isSpeakerLabel(name) else { return nil }
        let gloss = zh != nil && en != nil && en != zh ? en : nil
        let keys = Self.spellings(name, aliases: [gloss].compactMap(\.self))
        guard keys.isDisjoint(with: suppressed) else { return nil }
        let found = matches(keys)
        if found.count == 1 { return cards[found[0]].type == type ? found[0] : nil }
        guard found.isEmpty, codeCount(in: sessionID) < Self.sessionCodeCap else { return nil }
        cards.append(ResearchCard(id: UUID(), name: name, aliases: [], type: type, origin: .emerged, pinned: false, entries: [],
                                  gloss: gloss, provenance: .spontaneous))
        return cards.count - 1
    }

    // MARK: - Edits

    enum Edit: Sendable { case rename(UUID, String), pin(UUID, Bool), merge(UUID, into: UUID), drop(UUID) }

    mutating func edit(_ edit: Edit) {
        switch edit {
        case let .rename(id, name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let i = cards.firstIndex(where: { $0.id == id }), matches(Self.spellings(name, aliases: [])).allSatisfy({ $0 == i }) else { return }
            let old = cards[i].name
            if old != name {
                cards[i].aliases.append(old); cards[i].name = name
            }
        case let .pin(id, value):
            if let i = cards.firstIndex(where: { $0.id == id }) {
                cards[i].pinned = value
            }
        case let .drop(id):
            guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
            let removed = cards.remove(at: i)
            suppressed.formUnion(Self.spellings(removed.name, aliases: removed.aliases))
        case let .merge(from, into):
            guard from != into, let source = cards.first(where: { $0.id == from }), let index = cards.firstIndex(where: { $0.id == into }) else { return }
            var aliases = Set(cards[index].aliases)
            aliases.formUnion(source.aliases)
            aliases.insert(source.name)
            if let gloss = source.gloss { aliases.insert(gloss) }
            aliases.remove(cards[index].name)
            if let gloss = cards[index].gloss { aliases.remove(gloss) }
            cards[index].aliases = aliases.sorted()
            let existing = Set(cards[index].entries.map(\.id))
            cards[index].entries += source.entries.filter { !existing.contains($0.id) }
            cards[index].seeded = cards[index].seeded || source.seeded
            cards[index].pinned = cards[index].pinned || source.pinned
            cards[index].gloss = cards[index].gloss ?? source.gloss
            let qids = (cards[index].qids ?? []) + (source.qids ?? []).filter { !(cards[index].qids ?? []).contains($0) }
            cards[index].qids = qids.isEmpty ? nil : qids
            if let votes = source.votes {
                cards[index].votes = (cards[index].votes ?? []) + votes.filter { vote in
                    !(cards[index].votes ?? []).contains { $0.sessionID == vote.sessionID && Self.key($0.choice) == Self.key(vote.choice) }
                }
            }
            for key in Array(redirects.keys) where redirects[key] == from {
                redirects[key] = into
            }
            redirects[from.uuidString] = into
            cards.removeAll { $0.id == from }
        }
    }

    func scoped(to sessionID: String) -> Self {
        var copy = self
        copy.sessions = sessions.filter { $0.id == sessionID }
        copy.cards = cards.compactMap { card in
            let card = card.session(sessionID)
            return card.hasEvidence || card.seeded ? card : nil
        }
        return copy
    }
}

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - Brief

extension ResearchCodebook {
    /// The short brief every codebook call gets (1.6, about 400 to 600
    /// characters): objective, client brand, stimulus codes, guide section
    /// titles, client questions and hypotheses. Pure, so tests can read it.
    static func brief(book: ResearchCodebook, guide: GuideDocument?, stimulusCodes: [String], limit: Int = 600) -> String {
        func clip(_ text: String, _ max: Int) -> String {
            text.count <= max ? text : String(text.prefix(max - 1)) + "…"
        }
        func name(_ card: ResearchCard) -> String {
            [card.name, card.gloss].compactMap(\.self).joined(separator: " ")
        }
        var parts: [String] = []
        if let objective = book.objective { parts.append("Objective: " + clip(objective, 160) + ".") }
        let client = book.cards.filter { $0.clientBrand == true }.map(name)
        if !client.isEmpty { parts.append("Client brand: " + client.prefix(4).joined(separator: "; ") + ".") }
        if !stimulusCodes.isEmpty { parts.append("Stimulus: " + stimulusCodes.prefix(12).joined(separator: ", ") + ".") }
        if let guide {
            parts.append("Guide: " + guide.sections.map { clip("\($0.id) \($0.title)", 40) }.prefix(10).joined(separator: "; ") + ".")
        }
        let questions = book.cards.filter { $0.type == .clientQuestion && $0.seeded }.map { clip($0.name, 90) }
        if !questions.isEmpty { parts.append("Client questions: " + questions.prefix(4).joined(separator: "; ") + ".") }
        let hypotheses = book.cards.filter { $0.type == .hypothesis && $0.seeded }.map { clip(name($0), 90) }
        if !hypotheses.isEmpty { parts.append("Hypotheses: " + hypotheses.prefix(4).joined(separator: "; ") + ".") }
        return clip(parts.joined(separator: " "), limit)
    }
}

// MARK: - Live topic map

/// One code on the live rail: its quote count in one session, its tone, and
/// what its type needs: both sides of a tension, the tally of a vote, the
/// quotes for and against a hypothesis, a client question's status.
struct ResearchTopic: Equatable, Identifiable, Sendable {
    struct Side: Equatable, Sendable {
        let offsetMs: Int
        let words: String

        /// A short call clock for the narrow rail: 8:05, or 1:02:03.
        static func clock(_ ms: Int) -> String {
            let seconds = max(0, ms) / 1000
            return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }

    struct Tally: Equatable, Sendable {
        let choice: String
        let count: Int
    }

    let id: UUID
    /// The emic name first: the respondents' Chinese words when there are any.
    let name: String
    let gloss: String?
    let type: ResearchCardType
    /// Quotes, never people.
    let mentions: Int
    let valence: ResearchValence
    /// The latest quote's transcript offset, so the rail can tell which
    /// topic moved last.
    let latestOffsetMs: Int
    var provenance: ResearchProvenance?
    var sides: [Side] = []
    var tallies: [Tally] = []
    var support = 0
    var against = 0
    var status: ResearchQuestionStatus?

    /// One line for a tooltip or a VoiceOver label.
    var spoken: String {
        var parts = [[name, gloss].compactMap(\.self).joined(separator: ", "), type.label]
        switch type {
        case .vote: parts.append(tallies.map { "\($0.choice) \($0.count)" }.joined(separator: ", "))
        case .hypothesis: parts.append("\(support) for, \(against) against")
        case .clientQuestion: parts.append(status?.rawValue ?? "open")
        default: parts.append("\(mentions) \(mentions == 1 ? "quote" : "quotes")")
        }
        if type.isTheme || type == .brand { parts.append(valence.rawValue) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The codebook's codes grouped for the live rail. People and organisations
/// are never shown: the rail is about what was said, not who said it.
struct ResearchTopicMap: Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case tensions, votes, hypotheses, questions, brands, themes

        var title: String {
            switch self {
            case .tensions: "Tensions"
            case .votes: "Votes"
            case .hypotheses: "Hypotheses"
            case .questions: "Client questions"
            case .brands: "Brands"
            case .themes: "Themes"
            }
        }

        /// Chips, not rows: brands and themes.
        var isChips: Bool {
            self == .brands || self == .themes
        }

        init?(_ type: ResearchCardType) {
            switch type {
            case .tension: self = .tensions
            case .vote: self = .votes
            case .hypothesis: self = .hypotheses
            case .clientQuestion: self = .questions
            case .brand: self = .brands
            case .person, .org: return nil
            default: self = .themes
            }
        }
    }

    struct Section: Equatable, Sendable {
        let group: Group
        let topics: [ResearchTopic]
    }

    var sections: [Section] = []
    /// Codes with quotes left out by the cap.
    var hidden = 0

    var shown: Int {
        sections.reduce(0) { $0 + $1.topics.count }
    }

    var total: Int {
        shown + hidden
    }

    /// The shown topic with the latest quote.
    var newestID: UUID? {
        sections.flatMap(\.topics).max { $0.latestOffsetMs < $1.latestOffsetMs }?.id
    }
}

extension ResearchCodebook {
    static let topicLimit = 18

    /// A pure read of the cards for the live rail: no LLM call, no state.
    /// Counts only the given session's quotes (all sessions when nil) and
    /// drops codes with none. When more than `limit` qualify, pinned codes
    /// and the most quoted stay. Topics keep the codebook's own card order,
    /// so a chip never moves when its count changes.
    func topicMap(sessionID: String? = nil, limit: Int = topicLimit) -> ResearchTopicMap {
        struct Candidate {
            let index: Int
            let pinned: Bool
            let group: ResearchTopicMap.Group
            let topic: ResearchTopic
        }
        let candidates: [Candidate] = cards.enumerated().compactMap { index, whole in
            guard let group = ResearchTopicMap.Group(whole.type) else { return nil }
            let card = whole.session(sessionID)
            guard card.hasEvidence else { return nil }
            let votes = card.votes ?? []
            let offsets = card.entries.map(\.evidence.offsetMs) + card.entries.compactMap(\.counter?.offsetMs) + votes.map(\.offsetMs)
            var topic = ResearchTopic(id: card.id, name: card.name, gloss: card.gloss, type: card.type,
                                      mentions: card.type == .vote ? votes.map(\.count).reduce(0, +) : card.quoteCount,
                                      valence: Self.overallValence(card.entries.map(\.valence)),
                                      latestOffsetMs: offsets.max() ?? 0, provenance: card.provenance)
            switch card.type {
            case .tension:
                if let latest = card.entries.max(by: { $0.evidence.offsetMs < $1.evidence.offsetMs }) {
                    let sides = [latest.counter, latest.evidence].compactMap(\.self).sorted { $0.offsetMs < $1.offsetMs }
                    topic.sides = sides.map { quote in
                        let words = quote.turnID == latest.evidence.turnID ? latest.words : quote.original
                        return .init(offsetMs: quote.offsetMs, words: words)
                    }
                }
            case .vote:
                topic.tallies = votes.sorted { ($1.count, $0.choice) < ($0.count, $1.choice) }.map { .init(choice: $0.choice, count: $0.count) }
            case .hypothesis:
                (topic.support, topic.against) = card.support
            case .clientQuestion:
                topic.status = card.questionStatus ?? .open
            default: break
            }
            return Candidate(index: index, pinned: card.pinned, group: group, topic: topic)
        }
        let kept = candidates
            .sorted { ($0.pinned ? 0 : 1, -$0.topic.mentions, $0.index) < ($1.pinned ? 0 : 1, -$1.topic.mentions, $1.index) }
            .prefix(max(0, limit))
        let keptIndexes = Set(kept.map(\.index))
        let ordered = candidates.filter { keptIndexes.contains($0.index) }
        let sections = ResearchTopicMap.Group.allCases.compactMap { group -> ResearchTopicMap.Section? in
            let topics = ordered.filter { $0.group == group }.map(\.topic)
            return topics.isEmpty ? nil : ResearchTopicMap.Section(group: group, topics: topics)
        }
        return ResearchTopicMap(sections: sections, hidden: candidates.count - kept.count)
    }

    /// One tone for a topic: mixed when any quote is mixed or the quotes
    /// pull both ways, otherwise the one direction they have.
    static func overallValence(_ values: [ResearchValence]) -> ResearchValence {
        let positive = values.contains(.positive), negative = values.contains(.negative)
        if values.contains(.mixed) || (positive && negative) { return .mixed }
        if positive { return .positive }
        if negative { return .negative }
        return .neutral
    }
}
