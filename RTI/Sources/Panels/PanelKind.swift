import Foundation

/// Kinds of user-spawnable analysis panels. New kinds are additive — the
/// spawn protocol round-trips through JSON, so the model can only ever
/// produce a kind we already ship a renderer for.
enum PanelKind: String, Codable, CaseIterable {
    /// Live keyword/regex counter against the streaming transcript.
    case counter
    /// Periodic LLM-generated cards (custom prompt run every N minutes).
    case periodicCards = "periodic_cards"
}

/// One configured panel. The `kind` discriminates the `config` payload,
/// which is stored on disk as a JSON blob — keeps the schema flexible as
/// the kind library grows without a migration per added field.
struct PanelConfig: Codable, Equatable {
    var counter: CounterConfig?
    var periodicCards: PeriodicCardsConfig?
}

struct CounterConfig: Codable, Equatable {
    /// Display label for the counter (e.g. "Acme mentions").
    var label: String
    /// What to match in each transcript entry.
    var match: MatchSpec
}

enum MatchSpec: Codable, Equatable {
    case keyword(value: String, caseInsensitive: Bool)
    case regex(pattern: String)

    enum CodingKeys: String, CodingKey { case type, value, caseInsensitive, pattern }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "keyword":
            let v = try c.decode(String.self, forKey: .value)
            let ci = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? true
            self = .keyword(value: v, caseInsensitive: ci)
        case "regex":
            self = .regex(pattern: try c.decode(String.self, forKey: .pattern))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown match type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyword(let v, let ci):
            try c.encode("keyword", forKey: .type)
            try c.encode(v, forKey: .value)
            try c.encode(ci, forKey: .caseInsensitive)
        case .regex(let p):
            try c.encode("regex", forKey: .type)
            try c.encode(p, forKey: .pattern)
        }
    }

    /// True when `text` contains any match for this spec. Case-insensitive
    /// keyword matches lowercase both sides; regex compiles each call but
    /// the volume (per transcript turn) is tiny.
    func matches(_ text: String) -> Bool {
        switch self {
        case .keyword(let value, let caseInsensitive):
            let needle = caseInsensitive ? value.lowercased() : value
            let hay = caseInsensitive ? text.lowercased() : text
            return hay.contains(needle)
        case .regex(let pattern):
            return (try? NSRegularExpression(pattern: pattern, options: []))?
                .firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

struct PeriodicCardsConfig: Codable, Equatable {
    /// Display label for the panel (e.g. "Striking quotes").
    var label: String
    /// Prompt the LLM runs against the recent transcript window each tick.
    var prompt: String
    /// Generation interval in seconds. Clamped at runtime to [60, 600] to
    /// stop a hallucinated config from melting the API budget.
    var intervalSeconds: Double
}
