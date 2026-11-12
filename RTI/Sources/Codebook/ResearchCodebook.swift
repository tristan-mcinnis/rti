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

enum ResearchCardType: String, CaseIterable, Codable, Sendable { case brand, person, org, concept, hypothesis }
enum ResearchValence: String, CaseIterable, Codable, Sendable { case positive, negative, mixed, neutral }

struct ResearchEntry: Codable, Equatable, Identifiable, Sendable {
    let point: String
    var evidence: ResearchQuote
    let valence: ResearchValence
    let inferredName: String?
    var id: String {
        evidence.id
    }
}

struct ResearchCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
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

    var summary: String {
        var seen: Set<String> = []
        return entries.reversed().compactMap { seen.insert($0.point).inserted ? $0.point : nil }
            .prefix(3).reversed().joined(separator: " ")
    }
}

struct ResearchProposal: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let name: String
        let aliases: [String]?
        let type: ResearchCardType
        let turnID: String
        let point: String
        let valence: ResearchValence
    }

    struct NameHint: Decodable, Sendable {
        let moderatorTurnID: String
        let respondentTurnID: String
        let name: String
    }

    let entries: [Item]
    let names: [NameHint]?
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

    var schemaVersion = 1
    var projectDirectory: String?
    var projectMergePending: Bool?
    var sessions: [Session] = []
    var cards: [ResearchCard] = []
    var suppressed: Set<String> = []
    var redirects: [String: UUID] = [:]

    static func key(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func spellings(_ name: String, aliases: [String]) -> Set<String> {
        let parts = name.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .components(separatedBy: CharacterSet(charactersIn: "()"))
        return Set(([name] + aliases + parts).map(key).filter { !$0.isEmpty })
    }

    private func matches(_ keys: Set<String>) -> [Int] {
        cards.indices.filter { !keys.isDisjoint(with: Self.spellings(cards[$0].name, aliases: cards[$0].aliases)) }
    }

    mutating func seed(_ name: String, type: ResearchCardType = .concept) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Self.spellings(clean, aliases: [])
        guard !keys.isEmpty, keys.isDisjoint(with: suppressed) else { return }
        let found = matches(keys)
        if found.count == 1 {
            cards[found[0]].seeded = true
        }
        if found.isEmpty {
            cards.append(ResearchCard(id: UUID(), name: clean, aliases: [], type: type, origin: .seeded, pinned: false, entries: []))
        }
    }

    mutating func apply(_ proposal: ResearchProposal, sources: [ResearchQuote]) {
        let turns = Dictionary(uniqueKeysWithValues: sources.map { ($0.turnID, $0) })
        var hints: [String: String] = [:]
        for hint in proposal.names ?? [] {
            let name = hint.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let question = turns[hint.moderatorTurnID], question.speaker.moderator,
                  question.original.contains(name), let reply = turns[hint.respondentTurnID], !reply.speaker.moderator,
                  reply.offsetMs >= question.offsetMs, reply.offsetMs - question.offsetMs <= 30000,
                  !sources.contains(where: { $0.offsetMs > question.offsetMs && $0.offsetMs < reply.offsetMs && !$0.speaker.moderator }) else { continue }
            hints[reply.turnID] = name
        }
        var created = 0
        for item in proposal.entries {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let point = item.point.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !point.isEmpty, let quote = turns[item.turnID], !quote.speaker.moderator else { continue }
            let aliases = (item.aliases ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let keys = Self.spellings(name, aliases: aliases)
            guard keys.isDisjoint(with: suppressed) else { continue }
            let found = matches(keys)
            guard found.count <= 1 else { continue }
            let index: Int
            if let first = found.first {
                index = first
            } else {
                guard created < 8 else { continue }
                index = cards.count
                cards.append(ResearchCard(id: UUID(), name: name, aliases: [], type: item.type, origin: .emerged, pinned: false, entries: []))
                created += 1
            }
            for alias in [name] + aliases where alias != cards[index].name && !cards[index].aliases.contains(alias) {
                cards[index].aliases.append(alias)
            }
            guard !cards[index].entries.contains(where: { $0.id == quote.id }) else { continue }
            cards[index].entries.append(ResearchEntry(point: point, evidence: quote, valence: item.valence, inferredName: hints[quote.turnID]))
        }
    }

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
            cards[index].aliases = Array(Set(cards[index].aliases + source.aliases + [source.name])).sorted()
            let existing = Set(cards[index].entries.map(\.id))
            cards[index].entries += source.entries.filter { !existing.contains($0.id) }
            cards[index].seeded = cards[index].seeded || source.seeded
            cards[index].pinned = cards[index].pinned || source.pinned
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
            var card = card
            card.entries = card.entries.filter { $0.evidence.sessionID == sessionID }
            return card.entries.isEmpty && !card.seeded ? nil : card
        }
        return copy
    }
}
