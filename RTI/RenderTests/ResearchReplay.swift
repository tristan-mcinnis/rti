import Foundation
import RTICore
import XCTest

/// The invented research replay (`RTI/Tests/Fixtures/ResearchReplay`): a
/// 60-minute Mandarin group for an invented oat drink, Lumo 露慕, with every
/// failure the 2026-11-12 judges found scripted at a known minute. The
/// fixture is read by path; it is never bundled. Rebuild `transcript.jsonl`
/// from `script.tsv` with `scripts/research-replay-fixture.py`.
enum ResearchReplayFixture {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/ResearchReplay", isDirectory: true)

    /// One scripted line (`script.tsv`). Filler lines have no key.
    struct Line: Sendable {
        let key: String
        let index: Int
        let leg: String
        let text: String
    }

    /// One journal batch and when the app would receive it: half a second
    /// after its last word.
    struct Batch {
        let leg: String
        let tokens: [SonioxWord]
        let arrivalMs: Int
    }

    static func lines() throws -> [Line] {
        let text = try String(contentsOf: folder.appendingPathComponent("script.tsv"), encoding: .utf8)
        var lines: [Line] = []
        for raw in text.split(separator: "\n") where !raw.hasPrefix("#") {
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 4 else { continue }
            lines.append(Line(key: columns[0], index: lines.count, leg: columns[2] == "mic" ? "mic" : "system", text: columns[3]))
        }
        return lines
    }

    static func batches() throws -> [Batch] {
        let data = try Data(contentsOf: folder.appendingPathComponent("transcript.jsonl"))
        let decoder = JSONDecoder()
        return try data.split(separator: 10).map { line in
            let batch = try decoder.decode(SonioxLiveJournal.Batch.self, from: Data(line))
            let end = batch.tokens.map(\.endMs).max() ?? 0
            return Batch(leg: batch.leg, tokens: batch.tokens, arrivalMs: batch.baseMs + end + 500)
        }
    }

    static var guideURL: URL {
        folder.appendingPathComponent("guide.json")
    }

    static func guide() throws -> GuideDocument {
        try GuideDocument.parse(Data(contentsOf: guideURL))
    }

    static func seeds() throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent("codebook-seed.md"), encoding: .utf8).components(separatedBy: .newlines)
    }

    static func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func answerKey() throws -> [String: Any] {
        try json("answer-key.json")
    }

    /// Letters and digits only, lowercased: how a turn is matched to its line.
    static func normalized(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }
}

/// The model side of a replay. Recorded mode serves `responses/*.json`:
/// each pass gets the replies whose trigger line it carries, with `{{Lnnn}}`
/// and `{{code:NAME}}` filled in from what the prompt itself shows. Live mode
/// (Layer B) forwards to a provider. Both modes log every exchange and learn
/// which turn ID carries each scripted line.
final class ResearchReplayResponder: @unchecked Sendable {
    enum Pass: String, CaseIterable, Sendable {
        case guide, codebook, synthesis, auto
    }

    struct Exchange: Sendable {
        let pass: Pass
        let characters: Int
        let system: String
        let user: String
        let reply: String
    }

    typealias Provider = @Sendable ([LLMMessage]) async throws -> String

    static let autoWindowMarker = "New conversation since the last pass (act on this):\n"

    private let lock = NSLock()
    private let lines: [ResearchReplayFixture.Line]
    private let normalizedLines: [String]
    private let tables: [Pass: [String: Any]]
    private let provider: Provider?
    private var turnIDs: [String: String] = [:]
    private var servedSynthesis: Set<Int> = []
    private var log: [Exchange] = []

    /// Recorded replies from `responses/`.
    init(lines: [ResearchReplayFixture.Line]) throws {
        self.lines = lines
        normalizedLines = lines.map { ResearchReplayFixture.normalized($0.text) }
        var tables: [Pass: [String: Any]] = [:]
        for pass in Pass.allCases {
            tables[pass] = try ResearchReplayFixture.json("responses/\(pass.rawValue).json")
        }
        self.tables = tables
        provider = nil
    }

    /// Every reply from `provider`; nothing recorded is served.
    init(lines: [ResearchReplayFixture.Line], provider: @escaping Provider) {
        self.lines = lines
        normalizedLines = lines.map { ResearchReplayFixture.normalized($0.text) }
        tables = [:]
        self.provider = provider
    }

    var exchanges: [Exchange] {
        lock.withLock { log }
    }

    var learnedTurnIDs: [String: String] {
        lock.withLock { turnIDs }
    }

    /// A background request whose replies come from this responder. The
    /// codebook's filing and synthesis passes share one request factory, so
    /// a synthesis input (it carries a call minute) is told apart here.
    func request(_ pass: Pass) -> LLMRequest {
        LLMRequest(collectStream: { [self] messages, _, _, _ in
            let text = try await reply(pass, messages: messages)
            return LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
    }

    private func reply(_ requested: Pass, messages: [LLMMessage]) async throws -> String {
        let system = messages.count > 1 ? messages.first?.content ?? "" : ""
        let user = messages.last?.content ?? ""
        let input = (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any]
        let pass: Pass = requested == .codebook && input?["minute"] != nil ? .synthesis : requested
        let reply: String
        if let provider {
            lock.withLock { learn(from: input) }
            reply = try await provider(messages)
        } else {
            reply = lock.withLock { recorded(pass, user: user, input: input) }
        }
        let characters = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        lock.withLock { log.append(Exchange(pass: pass, characters: characters, system: system, user: user, reply: reply)) }
        return reply
    }

    // MARK: Turn IDs

    private func learn(from input: [String: Any]?) {
        for turn in input?["turns"] as? [[String: Any]] ?? [] {
            if let id = turn["id"] as? String, let text = turn["text"] as? String {
                learn(id: id, text: text)
            }
        }
    }

    /// The first unmapped line this turn reads: the whole line, or the
    /// first piece of a line split at its question mark.
    private func learn(id: String, text: String) {
        let turn = ResearchReplayFixture.normalized(text)
        guard !turn.isEmpty, !turnIDs.values.contains(id) else { return }
        for (index, line) in lines.enumerated() where turnIDs[line.key] == nil {
            let words = normalizedLines[index]
            if words == turn || (turn.count >= 4 && words.hasPrefix(turn)) {
                turnIDs[line.key] = id
                return
            }
        }
    }

    // MARK: Recorded replies

    private func recorded(_ pass: Pass, user: String, input: [String: Any]?) -> String {
        guard let table = tables[pass] else { return "{}" }
        learn(from: input)
        let replies = table["replies"] as? [[String: Any]] ?? []
        var chosen: [[String: Any]] = []
        switch pass {
        case .guide:
            let fresh = Set((input?["turns"] as? [[String: Any]] ?? []).filter { $0["newEvidence"] as? Bool == true }
                .compactMap { $0["id"] as? String })
            chosen = replies.filter { ($0["when"] as? String).flatMap { turnIDs[$0] }.map(fresh.contains) ?? false }
        case .codebook:
            // Entry by entry: a model only cites the turns it was sent.
            let batch = Set((input?["turns"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            let entries = (table["entries"] as? [[String: Any]] ?? []).filter { entry in
                guard let placeholder = entry["turnID"] as? String else { return false }
                return turnIDs[String(placeholder.dropFirst(2).dropLast(2))].map(batch.contains) ?? false
            }
            chosen = entries.isEmpty ? [] : [["reply": ["entries": entries, "names": [Any]()]]]
        case .synthesis:
            let minute = input?["minute"] as? Int ?? 0
            if let index = replies.indices.last(where: { (replies[$0]["from_minute"] as? Int ?? .max) <= minute }),
               servedSynthesis.insert(index).inserted
            {
                chosen = [replies[index]]
            }
        case .auto:
            chosen = replies.filter { autoTriggered($0, user: user) }
        }
        let known = (input?["known"] as? [[String: Any]]) ?? (input?["codes"] as? [[String: Any]]) ?? []
        let filled = chosen.compactMap { $0["reply"] }.map { substitute($0, known: known) }
        let reply: Any = filled.count == 1 ? filled[0] : merge(filled, pass: pass, fallback: table["default"] ?? [:])
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The trigger line is in the pass's new window, and no scripted line
    /// after `until` is.
    private func autoTriggered(_ entry: [String: Any], user: String) -> Bool {
        guard let key = entry["when"] as? String, let index = lines.firstIndex(where: { $0.key == key }),
              let range = user.range(of: Self.autoWindowMarker) else { return false }
        let window = ResearchReplayFixture.normalized(String(user[range.upperBound...]))
        guard window.contains(String(normalizedLines[index].prefix(12))) else { return false }
        if let until = entry["until"] as? String, let last = lines.firstIndex(where: { $0.key == until }) {
            return !lines.indices.contains { $0 > last && window.contains(String(normalizedLines[$0].prefix(12))) }
        }
        return true
    }

    private func substitute(_ value: Any, known: [[String: Any]]) -> Any {
        if let text = value as? String, text.hasPrefix("{{"), text.hasSuffix("}}") {
            let inner = String(text.dropFirst(2).dropLast(2))
            if inner.hasPrefix("code:") {
                let name = String(inner.dropFirst(5))
                let code = known.first { code in
                    [code["name_zh"], code["name_en"]].contains { ($0 as? String) == name }
                        || (code["aliases"] as? [String] ?? []).contains(name)
                }
                return code?["id"] ?? NSNull()
            }
            return turnIDs[inner] ?? inner
        }
        if let array = value as? [Any] {
            return array.map { substitute($0, known: known) }
        }
        if let object = value as? [String: Any] {
            return object.mapValues { substitute($0, known: known) }
        }
        return value
    }

    /// Several triggered replies in one pass: their lists joined, the last
    /// guide suggestion kept as written.
    private func merge(_ replies: [Any], pass: Pass, fallback: Any) -> Any {
        guard !replies.isEmpty else { return fallback }
        let objects = replies.compactMap { $0 as? [String: Any] }
        switch pass {
        case .guide:
            var merged: [String: Any] = ["suggestion": NSNull(), "evidence": [Any](), "cells": [Any]()]
            for object in objects {
                merged["cells"] = (merged["cells"] as? [Any] ?? []) + (object["cells"] as? [Any] ?? [])
                if let suggestion = object["suggestion"], !(suggestion is NSNull) {
                    merged["suggestion"] = suggestion
                    merged["evidence"] = object["evidence"] ?? [Any]()
                }
            }
            return merged
        case .codebook:
            return ["entries": objects.flatMap { $0["entries"] as? [Any] ?? [] },
                    "names": objects.flatMap { $0["names"] as? [Any] ?? [] }]
        case .auto:
            return ["cards": objects.flatMap { $0["cards"] as? [Any] ?? [] }]
        case .synthesis:
            return objects.last ?? fallback
        }
    }
}

/// One replay of the fixture through the real live controllers: the shared
/// coordinator (`receiveTranscriptWordsForProof`), the shared guide
/// controller, a codebook controller on a temporary folder, and an Auto
/// controller on a simulated clock. The scheduler is stood in for: guide at
/// +40 s, codebook at +80 s and synthesis at +100 s of each 120 s tick (the
/// app's staggered offsets), and an Auto tick every `stepSeconds`, which
/// stands in for the 7 s debounce (each tick still waits for the floor).
@MainActor
enum ResearchReplayRun {
    struct Options {
        var guide = true
        var minutes = 60
        var stepSeconds = 10
    }

    struct AcceptedCard {
        let card: AutoAssistCard
        let atMs: Int
    }

    struct GuideCheck {
        let atMs: Int
        let gaps: [GuideGap]
        let furthestQID: String?
        let lastError: String?
    }

    struct Result {
        var sessionID = ""
        var cards: [AcceptedCard] = []
        /// Each Auto pass that sent a request, with the cards it added.
        var autoPasses: [(atMs: Int, added: Int)] = []
        var guideChecks: [GuideCheck] = []
        var book = ResearchCodebook()
        var cells: [GuideCell] = []
        var positions: [Int: String] = [:]
        var gapsAtEnd: [GuideGap] = []
        var captureIncomplete: Bool?
        var guideErrors: [String] = []
        var codebookErrors: [String] = []
        var exchanges: [ResearchReplayResponder.Exchange] = []
        var turnIDs: [String: String] = [:]
        var shown = 0
    }

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func run(_ responder: ResearchReplayResponder, options: Options = Options(),
                    checkpointMinutes: [Int] = []) async throws -> Result
    {
        let batches = try ResearchReplayFixture.batches()
        let document = try ResearchReplayFixture.guide()
        var result = Result()

        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof(startedAt: start)
        defer { session.endTranscriptReplayForProof() }
        let sessionID = try XCTUnwrap(session.currentSessionId)
        result.sessionID = sessionID

        let guide = GuideSessionController.shared
        guide.useRequestForTest(responder.request(.guide))
        defer {
            guide.endSession(sessionID)
            guide.useRequestForTest(LLMRequest(priority: .background))
        }
        if options.guide {
            guide.start(sessionID: sessionID, guide: document, guideURL: ResearchReplayFixture.guideURL, group: "G1",
                        roster: [], rosterURL: nil, startedAt: start)
        }

        // The codebook's settle cutoff reads the wall clock, so its session
        // starts hours ago: every batch fed is a whole line, already settled.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rti-research-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let place = ResearchCodebookStore.Location(
            session: .init(id: sessionID, group: "G1", startedAt: Date().addingTimeInterval(-6 * 3600), folder: directory.lastPathComponent),
            directory: directory, project: nil
        )
        let prepared = try await ResearchCodebookStore.shared.update(
            place, .prepare(seeds: ResearchReplayFixture.seeds(), hypotheses: options.guide ? document.hypotheses ?? [] : [])
        )
        let codebook = ResearchCodebookController(makeRequest: { responder.request(.codebook) })
        codebook.attachForTest(prepared, at: place)

        let suite = "ResearchReplay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = start
        let auto = AutoAssistController(request: responder.request(.auto), callTypes: .inMemory(.research), guide: guide,
                                        codebook: codebook, defaults: defaults, now: { clock })
        auto.reset(for: sessionID)
        defer { auto.stop() }

        var next = 0
        for second in stride(from: 0, through: options.minutes * 60, by: options.stepSeconds) {
            let nowMs = second * 1000
            clock = start.addingTimeInterval(TimeInterval(second))
            while next < batches.count, batches[next].arrivalMs <= nowMs {
                session.receiveTranscriptWordsForProof(batches[next].tokens, channel: batches[next].leg)
                next += 1
            }
            switch second % 120 {
            case 40 where options.guide:
                await guide.generateLive(sessionId: sessionID, at: clock)
                let furthest = guide.guide.flatMap { $0.questions.indices.contains(guide.furthestIndex) ? $0.questions[guide.furthestIndex].qid : nil }
                result.guideChecks.append(GuideCheck(atMs: nowMs, gaps: guide.gaps(includeNotRecorded: true), furthestQID: furthest,
                                                     lastError: guide.lastError))
                if let error = guide.lastError {
                    result.guideErrors.append("\(second) s: \(error)")
                }
            case 80:
                await codebook.generateLive(sessionID: sessionID)
                if let error = codebook.error {
                    result.codebookErrors.append("\(second) s: \(error)")
                }
            case 100:
                await codebook.synthesize(sessionID: sessionID, nowMs: nowMs)
                if let error = codebook.error {
                    result.codebookErrors.append("\(second) s: \(error)")
                }
            default:
                break
            }
            let before = auto.cards.count
            let sent = responder.exchanges.count
            await auto.generate(sessionId: sessionID)
            let added = auto.cards.count - before
            if responder.exchanges.count > sent {
                result.autoPasses.append((nowMs, added))
            }
            result.cards += auto.cards.suffix(added).map { AcceptedCard(card: $0, atMs: nowMs) }
        }

        for minute in checkpointMinutes {
            result.positions[minute] = guide.questionID(atTranscriptMs: minute * 60000)
        }
        if options.guide {
            await guide.finish(sessionId: sessionID, entries: session.liveEntries, at: clock)
            result.captureIncomplete = guide.snapshot(for: sessionID)?.extraction.captureIncomplete
            result.cells = guide.extraction?.cells ?? []
            result.gapsAtEnd = guide.gaps(includeNotRecorded: true)
        }
        await codebook.finish(sessionID: sessionID, entries: session.liveEntries)
        result.book = codebook.book
        result.shown = auto.surfacedCards.count
        result.exchanges = responder.exchanges
        result.turnIDs = responder.learnedTurnIDs
        return result
    }
}

/// Scores a replay against `answer-key.json`. Layer A runs it on the
/// recorded replies (the scorer must give them full marks); Layer B runs it
/// on live model output.
@MainActor
struct ResearchReplayScore {
    struct Check {
        let id: String
        let passed: Bool
        let detail: String
    }

    let checks: [Check]
    let codebookRecall: Double
    let forbidden: [String]
    let checkpointsRight: Int
    let inputCharacters: Int
    let estimatedTokensPerHour: Int
    let calls: [String: Int]

    var summary: [String: Any] {
        ["codebookRecall": codebookRecall, "forbidden": forbidden, "checkpointsRight": checkpointsRight,
         "inputCharacters": inputCharacters, "estimatedInputTokensPerHour": estimatedTokensPerHour, "calls": calls,
         "checks": checks.map { ["id": $0.id, "passed": $0.passed, "detail": $0.detail] }]
    }

    /// The harness estimate: a CJK character is about 0.6 tokens, four other characters about one.
    static func estimatedTokens(_ text: String) -> Int {
        let cjk = text.unicodeScalars.filter { $0.value > 0x2E80 }.count
        return Int(Double(text.unicodeScalars.count - cjk) / 4 + Double(cjk) * 0.6) + 4
    }

    init(_ result: ResearchReplayRun.Result, key: [String: Any], minutes: Int = 60) {
        var checks: [Check] = []
        let ids = result.turnIDs
        func turns(_ lines: [String]) -> Set<String> {
            Set(lines.compactMap { ids[$0] })
        }

        // Codebook.
        let codebookKey = key["codebook"] as? [String: Any] ?? [:]
        let cards = result.book.cards.map { $0.session(result.sessionID) }
        var found = 0
        let required = codebookKey["required"] as? [[String: Any]] ?? []
        for item in required {
            let id = item["id"] as? String ?? "?"
            let types = Set(item["types"] as? [String] ?? [])
            let wanted = turns(item["lines"] as? [String] ?? [])
            let minLines = item["minLines"] as? Int ?? 0
            let match = cards.first { card in
                guard types.contains(card.type.rawValue) else { return false }
                if let name = item["name"] as? String, !(card.name.contains(name) || card.aliases.contains(name)) {
                    return false
                }
                if item["clientBrand"] as? Bool == true, card.clientBrand != true {
                    return false
                }
                if let aliases = item["aliases"] as? [String], !Set(aliases).isSubset(of: Set(card.aliases + [card.name])) {
                    return false
                }
                if let votes = item["votes"] as? [String: Int] {
                    let got = Dictionary((card.votes ?? []).map { ($0.choice, $0.count) }, uniquingKeysWith: { _, last in last })
                    return votes.allSatisfy { got[$0.key] == $0.value }
                }
                let cited = Set(card.entries.flatMap { [$0.evidence.turnID, $0.counter?.turnID].compactMap(\.self) })
                return cited.intersection(wanted).count >= minLines
            }
            if match != nil {
                found += 1
            }
            checks.append(Check(id: "codebook.\(id)", passed: match != nil, detail: match.map { "card \($0.name)" } ?? "no card"))
        }
        codebookRecall = required.isEmpty ? 1 : Double(found) / Double(required.count)

        var forbidden: [String] = []
        let rules = codebookKey["forbidden"] as? [String: Any] ?? [:]
        let types = Set(rules["types"] as? [String] ?? [])
        let names = rules["names"] as? [String] ?? []
        let evidence = turns(rules["evidenceLines"] as? [String] ?? [])
        for card in cards {
            let spellings = [card.name] + card.aliases
            if types.contains(card.type.rawValue) {
                forbidden.append("type \(card.type.rawValue): \(card.name)")
            }
            if rules["speakerLabels"] as? Bool == true, spellings.contains(where: ResearchCodebook.isSpeakerLabel) {
                forbidden.append("speaker label: \(card.name)")
            }
            for name in names where spellings.contains(where: { $0.contains(name) }) {
                forbidden.append("name \(name): \(card.name)")
            }
            for pair in rules["apart"] as? [[String]] ?? [] where pair.allSatisfy({ part in spellings.contains { $0.contains(part) } }) {
                forbidden.append("merged \(pair.joined(separator: " + ")): \(card.name)")
            }
            if card.type != .vote {
                for entry in card.entries where evidence.contains(entry.evidence.turnID) {
                    forbidden.append("moderator or backchannel evidence \(entry.evidence.turnID) on \(card.name)")
                }
            }
        }
        for cell in result.cells {
            for quote in cell.orderedQuotes where evidence.contains(quote.turnID) {
                forbidden.append("guide quote \(quote.turnID) in \(cell.qid)")
            }
        }
        self.forbidden = forbidden

        // Guide position.
        let guideKey = key["guide"] as? [String: Any] ?? [:]
        let checkpoints = guideKey["checkpoints"] as? [[String: Any]] ?? []
        var right = 0
        for checkpoint in checkpoints {
            guard let minute = checkpoint["minute"] as? Int, let qid = checkpoint["qid"] as? String else { continue }
            let got = result.positions[minute]
            if got == qid {
                right += 1
            }
            checks.append(Check(id: "guide.position.\(minute)", passed: got == qid, detail: "want \(qid), got \(got ?? "none")"))
        }
        checkpointsRight = right

        // Auto.
        let autoKey = key["auto"] as? [String: Any] ?? [:]
        let hours = Double(minutes) / 60
        let accepted = result.cards
        let perHour = Double(accepted.count) / hours
        checks.append(Check(id: "auto.volume", passed: perHour <= Double(autoKey["maxShownPerHour"] as? Int ?? 25),
                            detail: "\(accepted.count) cards accepted, \(result.shown) shown, in \(minutes) min"))
        let patterns = (autoKey["templatePatterns"] as? [String] ?? []).map { $0.lowercased() }
        let templated = accepted.filter { card in
            let text = (card.card.text + " " + (card.card.textZH ?? "")).lowercased()
            return patterns.contains { text.contains($0) }
        }.count
        let share = accepted.isEmpty ? 0 : Double(templated) / Double(accepted.count)
        checks.append(Check(id: "auto.template", passed: share < (autoKey["maxTemplateShare"] as? Double ?? 0.2),
                            detail: "\(templated) of \(accepted.count) use a past-behaviour template"))
        let spoken = accepted.filter { $0.card.kind == .ask || $0.card.kind == .say }
        let withZH = spoken.filter { $0.card.textZH != nil }.count
        checks.append(Check(id: "auto.mandarin", passed: withZH == spoken.count,
                            detail: "\(withZH) of \(spoken.count) ASK and SAY cards carry a Mandarin line"))
        for item in autoKey["required"] as? [[String: Any]] ?? [] {
            let id = item["id"] as? String ?? "?"
            let from = Int((item["fromMinute"] as? Double ?? 0) * 60000)
            let by = Int((item["byMinute"] as? Double ?? 999) * 60000)
            let words = item["anyOf"] as? [String] ?? []
            let hit = accepted.first { card in
                guard card.card.kind.rawValue.lowercased() == (item["kind"] as? String ?? "").lowercased(), card.atMs >= from, card.atMs <= by else { return false }
                if item["contradiction"] as? Bool == true {
                    return AutoCardRules.isContradiction(card.card)
                }
                let text = (card.card.text + " " + card.card.why).lowercased()
                return words.isEmpty || words.contains { text.contains($0.lowercased()) }
            }
            checks.append(Check(id: "auto.\(id)", passed: hit != nil,
                                detail: hit.map { "\(TimeFormat.elapsedMs($0.atMs)) \($0.card.text)" } ?? "none in the window"))
        }

        // Volume.
        var calls: [String: Int] = [:]
        for exchange in result.exchanges {
            calls[exchange.pass.rawValue, default: 0] += 1
        }
        self.calls = calls
        inputCharacters = result.exchanges.reduce(0) { $0 + $1.characters }
        let tokens = result.exchanges.reduce(0) { $0 + Self.estimatedTokens($1.system) + Self.estimatedTokens($1.user) }
        estimatedTokensPerHour = Int(Double(tokens) / hours)
        self.checks = checks
    }
}

extension ResearchReplayRun.Result {
    /// Every exchange as files, plus the Auto timeline: for reading a run.
    func write(to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory.appendingPathComponent("exchanges"), withIntermediateDirectories: true)
        for (index, exchange) in exchanges.enumerated() {
            let name = String(format: "%03d-%@", index, exchange.pass.rawValue)
            let body = "SYSTEM\n\(exchange.system)\n\nUSER\n\(exchange.user)\n\nREPLY\n\(exchange.reply)\n"
            try body.write(to: directory.appendingPathComponent("exchanges/\(name).txt"), atomically: true, encoding: .utf8)
        }
        var timeline = autoPasses.map { "pass \(TimeFormat.elapsedMs($0.atMs)) added \($0.added)" }
        timeline += cards.map { "card \(TimeFormat.elapsedMs($0.atMs)) [\($0.card.kind.rawValue)] \($0.card.text) | \($0.card.textZH ?? "-")" }
        timeline += guideChecks.map { check in
            "guide \(TimeFormat.elapsedMs(check.atMs)) furthest \(check.furthestQID ?? "-") gaps "
                + check.gaps.map { "\($0.qid):\($0.detail)" }.joined(separator: ", ")
        }
        timeline += turnIDs.sorted { $0.key < $1.key }.map { "line \($0.key) = \($0.value)" }
        timeline += book.cards.map { card in
            "code [\(card.type.rawValue)] \(card.name) aliases \(card.aliases) quotes \(card.entries.map(\.evidence.turnID)) votes \((card.votes ?? []).map { "\($0.choice)=\($0.count)" })"
        }
        timeline += cells.map { "cell \($0.qid) \($0.coverage) quotes \($0.orderedQuotes.map(\.turnID)) tally \($0.tally ?? "-")" }
        try timeline.joined(separator: "\n").write(to: directory.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
    }
}
