import Foundation

/// One proactive suggestion surfaced by Auto mode while a meeting runs.
/// Ephemeral: cards accumulate in memory for the session and are dropped on
/// `clear()`. A card is an in-the-moment nudge for the user — something to say,
/// ask, recall, or flag, grounded in the meeting's project context.
public struct AutoAssistCard: Identifiable, Equatable {
    public let id = UUID()
    /// Wall-clock time the card was surfaced.
    public let timestamp: Date
    public let kind: AutoCardKind
    /// The suggestion itself (one line; what to say / ask / recall).
    public let text: String
    /// Why it's relevant right now (one short line), or empty.
    public let why: String
    /// The retrieved document the suggestion draws on, or nil when the model
    /// gave no handle that resolves to a document this pass actually injected.
    /// Built only by `AutoCardCitation`, never from model text.
    public let citation: VaultSearch.Citation?

    /// The icon and label for the card's source row. Reads the retrieved
    /// document's own name, so a fabricated label can never appear here.
    public var source: String? { citation?.label }

    public init(
        timestamp: Date,
        kind: AutoCardKind,
        text: String,
        why: String,
        citation: VaultSearch.Citation?
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.why = why
        self.citation = citation
    }
}

// MARK: - Assembly

public extension AutoAssistCard {
    /// Build one card from a decoded model item. This is the only path Auto uses
    /// to create cards, so tests exercise the same seam the running app does.
    ///
    /// `sourceID` is the handle the model emitted (the bracketed ID printed with
    /// the injected material, or a full vault-relative path). It resolves only
    /// by exact allowlist match against this pass's retrieved records — never by
    /// substring or title matching — so an invented name, a title typed back, or
    /// a title that merely contains a real one yields a card with no citation.
    static func make(
        kind: AutoCardKind,
        text: String,
        why: String?,
        sourceID: String?,
        citations: [VaultSearch.Citation],
        timestamp: Date = Date()
    ) -> AutoAssistCard? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return AutoAssistCard(
            timestamp: timestamp,
            kind: kind,
            text: body,
            why: (why ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            citation: AutoCardCitation.resolve(sourceID, in: citations)
        )
    }

    /// Build one card straight from a decoded wire item. Auto uses this call, so
    /// a test that decodes model JSON and calls it exercises the same decoding
    /// and citation gate the running app does.
    static func make(
        from item: AutoCardItem,
        citations: [VaultSearch.Citation],
        timestamp: Date = Date()
    ) -> AutoAssistCard? {
        make(
            kind: AutoCardKind(raw: item.kind ?? "RECALL"),
            text: item.text,
            why: item.why,
            sourceID: item.sourceHandle,
            citations: citations,
            timestamp: timestamp
        )
    }
}

/// Wire shape for one card in the model's JSON response. Everything but `text`
/// is optional so a slightly malformed item still decodes; the lenient array
/// decoder drops only the items it can't and keeps the rest of the batch.
public struct AutoCardItem: Decodable {
    public let kind: String?
    public let text: String
    public let why: String?
    /// Handle for a document the pass injected; the current prompt asks for it.
    public let sourceId: String?
    /// Older prompt shape: a free-form document name. Usable only as a handle.
    public let source: String?

    private enum CodingKeys: String, CodingKey {
        case kind, text, why, source, sourceId
        case sourceIdSnake = "source_id"
        case sourceIdCaps = "sourceID"
    }

    /// Accept the field under the spelling the model happened to emit. Every
    /// spelling is still only a handle candidate for the citation gate.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        why = try container.decodeIfPresent(String.self, forKey: .why)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
            ?? container.decodeIfPresent(String.self, forKey: .sourceIdSnake)
            ?? container.decodeIfPresent(String.self, forKey: .sourceIdCaps)
    }

    /// The handle the citation gate should try: the explicit source field when
    /// it says something, otherwise the older free-form `source`.
    public var sourceHandle: String? {
        AutoCardCitation.normalize(sourceId) ?? source
    }
}

/// Exact allowlist resolution for a model-emitted source handle. The allowed
/// set is the documents this pass retrieved, so a citation can only name a real
/// document, and the card's label comes from that record rather than the model.
public enum AutoCardCitation {
    /// Resolve a handle to one retrieved record, or nil. Accepted handles are an
    /// exact document ID (`S1`) or an exact vault-relative path. Nothing else:
    /// no title match, no substring, no splitting of compound strings.
    public static func resolve(_ raw: String?, in citations: [VaultSearch.Citation]) -> VaultSearch.Citation? {
        guard let handle = normalize(raw), !citations.isEmpty else { return nil }
        if let byID = citations.first(where: { $0.id.caseInsensitiveCompare(handle) == .orderedSame }) {
            return byID
        }
        let folded = handle.lowercased()
        return citations.first { $0.relativePath.lowercased() == folded }
    }

    /// Trim, drop one layer of wrapping brackets or quotes, and reject the
    /// model's ways of saying "none". Deliberately no splitting or partial
    /// extraction: `"S1, S2"` or `"S1 (Group 1 transcript)"` stays one handle
    /// and matches nothing.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let wrappers = CharacterSet(charactersIn: "[]()\"'`“”‘’「」")
        var handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = handle.unicodeScalars.first, wrappers.contains(first) {
            handle.removeFirst()
        }
        while let last = handle.unicodeScalars.last, wrappers.contains(last) {
            handle.removeLast()
        }
        handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { return nil }
        let noneValues: Set<String> = ["null", "nil", "none", "unknown", "n/a", "-", "—", "?"]
        guard !noneValues.contains(handle.lowercased()) else { return nil }
        return handle
    }
}

/// What kind of help a card offers. Drives its icon and label.
public enum AutoCardKind: String, Codable, Equatable, CaseIterable {
    /// A line the user could say or a point to make now.
    case say
    /// A question worth asking / a thread to follow up.
    case ask
    /// A relevant fact from the project to surface (prior finding, what a
    /// participant said, a status detail) — the "they just asked about X" case.
    case recall
    /// Something to watch: a contradiction with the project record, a claim to
    /// verify, a risk.
    case flag

    /// Tolerant parse of whatever the model emitted.
    public init(raw: String) {
        switch raw.uppercased() {
        case "SAY": self = .say
        case "ASK": self = .ask
        case "RECALL", "CONTEXT", "INFO": self = .recall
        case "FLAG", "WATCH": self = .flag
        default: self = .recall
        }
    }

    public var label: String {
        switch self {
        case .say: "Say"
        case .ask: "Ask"
        case .recall: "Recall"
        case .flag: "Flag"
        }
    }

    public var icon: String {
        switch self {
        case .say: "quote.bubble"
        case .ask: "questionmark.circle"
        case .recall: "books.vertical"
        case .flag: "exclamationmark.triangle"
        }
    }
}
