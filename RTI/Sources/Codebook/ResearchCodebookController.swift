import Foundation
import Observation
import RTICore

@Observable @MainActor
final class ResearchCodebookController {
    static let shared = ResearchCodebookController()
    private(set) var book = ResearchCodebook() {
        didSet { bookRevision &+= 1 }
    }
    private(set) var location: ResearchCodebookStore.Location?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var generating = false
    var seedText = ""
    var selectedOffset: Int?
    var pendingJump: Int?
    private var preparation: Task<ResearchCodebook, Error>?
    private var request: LLMRequest?
    private var passID = UUID()
    private var sealed = false
    @ObservationIgnored private var bookRevision = 0
    @ObservationIgnored private var topicCache: (revision: Int, session: String?, map: ResearchTopicMap)?
    // The ten-minute synthesis pass (1.5).
    private(set) var synthesizing = false
    @ObservationIgnored private var synthesisID = UUID()
    @ObservationIgnored private(set) var lastSynthesisMs: Int?
    @ObservationIgnored private(set) var quotesAtLastSynthesis = 0
    static let synthesisIntervalMs = 600_000
    /// A failed synthesis is tried again this long after, not at once.
    static let synthesisRetryMs = 120_000
    /// Each pass makes its own request so a new pass can cancel the old one.
    /// Tests pass a scripted request.
    @ObservationIgnored private let makeRequest: @MainActor () -> LLMRequest

    init(makeRequest: @escaping @MainActor () -> LLMRequest = { LLMRequest(priority: .background) }) {
        self.makeRequest = makeRequest
    }

    #if DEBUG
        func seedForRenderProof(_ fixture: ResearchCodebook) {
            book = fixture
        }

        /// Attach a fixture book at a fixture location, as `start` would
        /// once its preparation has loaded.
        func attachForTest(_ fixture: ResearchCodebook, at place: ResearchCodebookStore.Location) {
            start(sessionID: place.session.id, at: place.session.startedAt, callType: .internal)
            book = fixture; location = place
        }
    #endif

    func start(sessionID: String, at date: Date, callType: CallType) {
        preparation?.cancel(); request?.cancel(); passID = UUID()
        generating = false; sealed = false; error = nil; notice = nil; selectedOffset = nil; pendingJump = nil; book = ResearchCodebook(); location = nil
        synthesisID = UUID(); synthesizing = false; lastSynthesisMs = nil; quotesAtLastSynthesis = 0
        guard callType == .research, let directory = SessionArchive.sessionDirectory(startedAt: date) else { return }
        let group = GuidePreparation.shared.group
        let session = ResearchCodebook.Session(id: sessionID, group: group, startedAt: date, folder: directory.lastPathComponent)
        let place = ResearchCodebookStore.Location(session: session, directory: directory, project: ResearchCodebookStore.eligibleProject(MeetingContextStore.shared.workstreamItem))
        location = place
        let seeds = seedText.components(separatedBy: .newlines)
        seedText = ""
        let hypotheses = GuideSessionController.shared.guide?.hypotheses ?? []
        let task = Task { try await ResearchCodebookStore.shared.update(place, .prepare(seeds: seeds, hypotheses: hypotheses)) }
        preparation = task
        Task { await loadPrepared(task, at: place) }
    }

    private func loadPrepared(_ task: Task<ResearchCodebook, Error>, at place: ResearchCodebookStore.Location) async {
        do {
            let prepared = try await task.value
            if location == place, preparation != nil {
                book = prepared; preparation = nil
            }
        } catch {
            if location == place {
                self.error = error.localizedDescription
            }
        }
    }

    /// `moderatorShaped` is the shared role rule's verdict (`TurnRoles`): a
    /// question or restating summary on the system leg is moderator speech.
    static func attribution(for source: GuideTranscript.Source, moderatorShaped: Bool = false) -> ResearchQuote.Attribution {
        let turn = source.turn, assignments = SpeakerNameStore.shared
        let seat = assignments.guideAssignments[turn.speaker]?.seat
        let name = seat?.label ?? assignments.name(for: turn.speaker)
        let leg = SpeakerEvidence.leg(for: turn.speaker)
        let moderator = moderatorShaped || leg == "Me" || assignments.guideAssignments[turn.speaker]?.isModerator == true
        let confidence = SpeakerEvidence.resolve(speakerID: turn.speaker, named: name != nil && source.attributable)
        return ResearchQuote.Attribution(rawSpeaker: turn.speaker, label: confidence == .confirmed ? (name ?? leg) : leg,
                                         leg: leg, confidence: confidence.rawValue, seat: seat?.code, segment: seat?.segment, moderator: moderator)
    }

    static func evidence(_ source: GuideTranscript.Source, sessionID: String, group: String?,
                         moderatorShaped: Bool = false) -> ResearchQuote
    {
        let turn = source.turn
        let speaker = attribution(for: source, moderatorShaped: moderatorShaped)
        let context = SessionMarkers.shared.context(at: turn.startMs)
        let guideID = GuideSessionController.shared.questionID(atTranscriptMs: turn.startMs)
        let mentioned = stimulusMatcher().mentioned(in: turn.text)
        return ResearchQuote(sessionID: sessionID, turnID: turn.id, group: group, offsetMs: turn.startMs, original: turn.text,
                             speaker: speaker, guideQuestionAtCapture: guideID, questionID: context.guideQuestionID ?? guideID,
                             markerID: context.markerID, markerLabel: context.markerLabel, showEventID: context.showEventID, shownItemIDs: context.shownItemIDs, shownCodes: context.shownCodes,
                             packageRevision: context.packageRevision, revealRecorded: context.revealRecorded, mentionedCodes: mentioned.isEmpty ? nil : mentioned)
    }

    // MARK: - Stimulus codes (perf fix 7)

    /// One alternation regex per pinned stimulus package, rebuilt only when
    /// the package changes.
    private static var matcherCache: (key: [String], matcher: StimulusCodeMatcher)?

    static func stimulusMatcher(_ items: [StimulusPackage.Item]? = SessionMarkers.shared.pinned?.items) -> StimulusCodeMatcher {
        let codes = (items ?? []).map(\.code)
        if let cache = matcherCache, cache.key == codes { return cache.matcher }
        let matcher = StimulusCodeMatcher(codes: codes)
        matcherCache = (codes, matcher)
        return matcher
    }

    // MARK: - Prompt input

    /// A known code as the pass sees it: a short id, the names, the type,
    /// this session's quote count and the guide qids.
    struct KnownCode: Encodable, Equatable {
        let id: String
        let nameZh: String?
        let nameEn: String?
        let type: String
        let aliases: [String]
        let quotes: Int
        let qids: [String]
        enum CodingKeys: String, CodingKey {
            case id, type, aliases, quotes, qids
            case nameZh = "name_zh", nameEn = "name_en"
        }
    }

    static let knownLimit = 60

    /// The known codes for a prompt and the map from their short ids to card
    /// IDs. Pinned and seeded codes come first, then the most quoted. Schema
    /// 1 people and organisations are never sent.
    static func known(_ book: ResearchCodebook, sessionID: String?) -> (codes: [KnownCode], ids: [String: UUID]) {
        // Count each card once, not inside the comparator (perf: the project
        // book can hold hundreds of cards).
        let ranked = book.cards.enumerated().filter { $0.element.type.isCode }
            .map { (offset: $0.offset, card: $0.element, quotes: $0.element.quoteCount(in: sessionID)) }
            .sorted { a, b in
                (a.card.pinned || a.card.seeded ? 0 : 1, -a.quotes, a.offset) < (b.card.pinned || b.card.seeded ? 0 : 1, -b.quotes, b.offset)
            }.prefix(knownLimit)
        var ids: [String: UUID] = [:]
        let codes = ranked.enumerated().map { index, item in
            let id = "c\(index + 1)", card = item.card
            ids[id] = card.id
            let cjk = ResearchCodebook.containsCJK(card.name)
            return KnownCode(id: id, nameZh: cjk ? card.name : nil, nameEn: card.gloss ?? (cjk ? nil : card.name),
                             type: (card.type == .concept ? ResearchCardType.theme : card.type).rawValue,
                             aliases: Array(card.aliases.prefix(6)), quotes: item.quotes, qids: card.qids ?? [])
        }
        return (codes, ids)
    }

    private struct Input: Encodable {
        struct Turn: Encodable { let id: String; let role: String; let text: String }
        let brief: String
        let known: [KnownCode]
        let turns: [Turn]
    }

    private var brief: String {
        ResearchCodebook.brief(book: book, guide: GuideSessionController.shared.guide, stimulusCodes: Self.stimulusMatcher().codes)
    }

    private func messages(_ turns: [ResearchQuote], roles: [String: SpeechRole], sessionID: String) throws -> (messages: [LLMMessage], codes: [String: UUID]) {
        let known = Self.known(book, sessionID: sessionID)
        let input = Input(brief: brief, known: known.codes,
                          turns: turns.map { .init(id: $0.turnID, role: (roles[$0.turnID] ?? .unknown).rawValue, text: $0.original) })
        return try ([.init(role: "system", content: PromptStore.shared.text(.researchCodebook)),
                     .init(role: "user", content: String(decoding: JSONEncoder().encode(input), as: UTF8.self))], known.ids)
    }

    /// Typed and seat names never become codes (rule 11).
    private var forbiddenNames: Set<String> {
        let store = SpeakerNameStore.shared
        return Set(store.names.values).union(store.guideAssignments.values.compactMap { $0.seat?.label })
    }

    static func decode<T: Decodable>(_: T.Type, from response: String) throws -> T {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let first = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: first)...].dropLast(3))
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// The live rail's topic map, cached on the book revision so a redraw
    /// does not rebuild it.
    func liveTopicMap() -> ResearchTopicMap {
        let session = location?.session.id
        _ = book // register observation
        if let cache = topicCache, cache.revision == bookRevision, cache.session == session { return cache.map }
        let map = book.topicMap(sessionID: session)
        topicCache = (bookRevision, session, map)
        return map
    }

    @discardableResult
    func generate(sessionID: String, entries: [LiveEntry], finalDeadline: ContinuousClock.Instant? = nil) async -> Int? {
        await generate(sessionID: sessionID, finalDeadline: finalDeadline) { GuideTranscript.sources(from: entries) }
    }

    /// The live call's pass: its sources come from the coordinator's
    /// incremental utterance index (`GuideTranscript.liveSources`).
    @discardableResult
    func generateLive(sessionID: String) async -> Int? {
        await generate(sessionID: sessionID, finalDeadline: nil) { GuideTranscript.liveSources() }
    }

    private func generate(sessionID: String, finalDeadline: ContinuousClock.Instant?,
                          sources makeSources: () -> [GuideTranscript.Source]) async -> Int? {
        guard let place = location, place.session.id == sessionID, !generating, !sealed || finalDeadline != nil else { return nil }
        let token = UUID(); passID = token; generating = true
        defer {
            if passID == token {
                generating = false; request = nil
            }
        }
        if let preparation {
            await loadPrepared(preparation, at: place)
        }
        guard passID == token, !Task.isCancelled, let snapshot = book.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let cutoff = Int(Date().timeIntervalSince(place.session.startedAt) * 1000) - 2000
        let sources = PassSignpost.interval("codebook pass prep") { makeSources() }
        let pending = sources.filter { $0.attributable && !snapshot.consumed.contains($0.turn.id) && (finalDeadline != nil || $0.endMs <= cutoff) }
        let batch = GuideTranscript.batch(pending)
        guard let end = batch.map(\.endMs).max() else { return nil }
        // The shared role rule: mic-leg echoes of an in-room group are
        // consumed but never sent, and each sent turn carries a role hint.
        let echoes = GuideTranscript.echoIDs(batch, in: sources)
        let roleContext = GuideSessionController.shared.roleContext
        let roles = Dictionary(uniqueKeysWithValues: batch.map {
            ($0.turn.id, TurnRoles.role(speaker: $0.turn.speaker, text: $0.turn.text, context: roleContext))
        })
        // A bare backchannel (role unknown) is no evidence either: it files
        // like a moderator line, refused unless it is a tally.
        let quotes = batch.map {
            Self.evidence($0, sessionID: place.session.id, group: place.session.group, moderatorShaped: roles[$0.turn.id] != .respondent)
        }
        let sent = quotes.filter { !echoes.contains($0.turnID) }
        do {
            if sent.isEmpty {
                let next = try await ResearchCodebookStore.shared.update(place, .pass(ResearchProposal(entries: [], names: nil), quotes, endMs: end))
                guard location == place, passID == token else { return nil }
                book = next
                return end
            }
            let (prompt, codes) = try messages(sent, roles: roles, sessionID: place.session.id)
            let request = makeRequest(); self.request = request
            let response: String? = if let deadline = finalDeadline {
                await GuidePrompt.collectFinal(messages: prompt, request: request, deadline: deadline)
            } else {
                await request.collectAsync(messages: prompt, smart: false)
            }
            guard location == place, passID == token, !Task.isCancelled else { return nil }
            guard let response else { throw CocoaError(.coderInvalidValue) }
            let result = try Self.decode(ResearchProposal.self, from: response)
            let next = try await ResearchCodebookStore.shared.update(place, .pass(result, quotes, endMs: end, codes: codes, forbidden: forbiddenNames))
            guard location == place, passID == token else { return nil }
            book = next; error = nil
            return end
        } catch {
            if location == place, passID == token {
                self.error = "Codebook pass incomplete. \(error.localizedDescription)"
            }
            return nil
        }
    }

    // MARK: - Synthesis pass (1.5)

    /// Due every ten minutes of call time, once there are four codes and a
    /// new quote since the last synthesis. Pure, so tests can drive it.
    static func synthesisDue(nowMs: Int, lastMs: Int?, quotes: Int, quotesAtLast: Int, codes: Int) -> Bool {
        codes >= 4 && quotes > quotesAtLast && nowMs - (lastMs ?? 0) >= synthesisIntervalMs
    }

    private struct SynthesisInput: Encodable {
        struct Quote: Encodable { let turn: String; let minute: Int; let original: String }
        struct Code: Encodable {
            let id: String
            let nameZh: String?
            let nameEn: String?
            let type: String
            let quotes: Int
            let positive: Int
            let negative: Int
            let qids: [String]
            let best: [Quote]
            enum CodingKeys: String, CodingKey {
                case id, type, quotes, positive, negative, qids, best
                case nameZh = "name_zh", nameEn = "name_en"
            }
        }

        let brief: String
        let minute: Int
        let codes: [Code]
    }

    /// The synthesis input: this session's codes with counts and their
    /// earliest and latest quotes, at most 80 characters each.
    static func synthesisInput(_ book: ResearchCodebook, sessionID: String, brief: String, nowMs: Int) -> (json: Data, codes: [String: UUID])? {
        let known = known(book, sessionID: sessionID)
        let cards = Dictionary(book.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let codes: [SynthesisInput.Code] = known.codes.compactMap { code in
            guard let id = known.ids[code.id], let card = cards[id]?.session(sessionID), card.hasEvidence || card.type == .clientQuestion || card.type == .hypothesis else { return nil }
            let quotes = card.entries.filter { !$0.evidence.speaker.moderator }.sorted { $0.evidence.offsetMs < $1.evidence.offsetMs }
            let best = [quotes.first, quotes.count > 1 ? quotes.last : nil].compactMap(\.self).map {
                SynthesisInput.Quote(turn: $0.evidence.turnID, minute: $0.evidence.offsetMs / 60000, original: String($0.words.prefix(80)))
            }
            return .init(id: code.id, nameZh: code.nameZh, nameEn: code.nameEn, type: code.type, quotes: code.quotes,
                         positive: card.entries.filter { $0.valence == .positive }.count, negative: card.entries.filter { $0.valence == .negative }.count,
                         qids: code.qids, best: best)
        }
        guard !codes.isEmpty, let json = try? JSONEncoder().encode(SynthesisInput(brief: brief, minute: nowMs / 60000, codes: codes)) else { return nil }
        return (json, known.ids)
    }

    /// One synthesis pass when due. Runs on the shared scheduler tick beside
    /// the filing pass, never after the call ends.
    func synthesize(sessionID: String, nowMs: Int? = nil) async {
        guard let place = location, place.session.id == sessionID, !sealed, !synthesizing, preparation == nil else { return }
        let now = nowMs ?? Int(Date().timeIntervalSince(place.session.startedAt) * 1000)
        // The clock check first: most ticks stop here without counting.
        guard now - (lastSynthesisMs ?? 0) >= Self.synthesisIntervalMs else { return }
        let quoteCount = book.quoteCount(in: sessionID)
        guard Self.synthesisDue(nowMs: now, lastMs: lastSynthesisMs, quotes: quoteCount, quotesAtLast: quotesAtLastSynthesis,
                                codes: book.codeCount(in: sessionID)),
            let input = Self.synthesisInput(book, sessionID: sessionID, brief: brief, nowMs: now) else { return }
        let token = UUID(); synthesisID = token; synthesizing = true
        defer {
            if synthesisID == token { synthesizing = false }
        }
        let quotesBefore = quotesAtLastSynthesis
        lastSynthesisMs = now; quotesAtLastSynthesis = quoteCount
        let prompt: [LLMMessage] = [.init(role: "system", content: PromptStore.shared.text(.researchCodebookSynthesis)),
                                    .init(role: "user", content: String(decoding: input.json, as: UTF8.self))]
        let response = await makeRequest().collectAsync(messages: prompt, smart: false)
        guard location == place, synthesisID == token, !sealed, !Task.isCancelled else { return }
        do {
            guard let response else { throw CocoaError(.coderInvalidValue) }
            let result = try Self.decode(ResearchSynthesis.self, from: response)
            let next = try await ResearchCodebookStore.shared.update(place, .synthesis(result, codes: input.codes))
            guard location == place, synthesisID == token else { return }
            book = next; error = nil
            // Tensions and hypotheses re-cite quotes already in the book.
            // Those links are not new quotes, so they never make the next pass due.
            quotesAtLastSynthesis = max(quotesAtLastSynthesis, next.quoteCount(in: sessionID))
        } catch {
            // Try again in two minutes, not at once, with or without a new quote.
            guard location == place, synthesisID == token else { return }
            lastSynthesisMs = now - Self.synthesisIntervalMs + Self.synthesisRetryMs
            quotesAtLastSynthesis = quotesBefore
            self.error = "Codebook synthesis incomplete. \(error.localizedDescription)"
        }
    }

    func finish(sessionID: String, entries: [LiveEntry]) async {
        guard let place = location, place.session.id == sessionID, !sealed else { return }
        request?.cancel(); passID = UUID(); generating = false; sealed = true
        synthesisID = UUID(); synthesizing = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await generate(sessionID: sessionID, entries: entries, finalDeadline: deadline) == nil {
                break
            }
        }
        let consumed = book.sessions.first { $0.id == sessionID }?.consumed ?? []
        let incomplete = GuideTranscript.sources(from: entries).contains { $0.attributable && !consumed.contains($0.turn.id) }
        do {
            let final = try await ResearchCodebookStore.shared.update(place, .finish(incomplete: incomplete))
            if location == place {
                book = final
            }
        } catch {
            if location == place {
                self.error = error.localizedDescription
            }
        }
    }

    func browseSelectedProject() async {
        guard !SessionCoordinator.shared.isRunning, SessionCoordinator.shared.phase != .finishing else { return }
        let item = MeetingContextStore.shared.workstreamItem
        let directory = ResearchCodebookStore.eligibleProject(item)
        guard let directory else {
            if location?.project != nil {
                book = ResearchCodebook(); location = nil
            }
            return
        }
        do {
            let existing = try await ResearchCodebookStore.shared.existingBook(in: directory)
            guard !Task.isCancelled, !SessionCoordinator.shared.isRunning, MeetingContextStore.shared.workstreamItem?.id == item?.id else { return }
            book = existing; location = nil; error = nil
            if let latest = existing.sessions.max(by: { $0.startedAt < $1.startedAt }),
               latest.folder == URL(fileURLWithPath: latest.folder).lastPathComponent
            {
                let root = VaultPaths.sessionsDirectory().resolvingSymlinksInPath()
                let sessionDir = root.appendingPathComponent(latest.folder).resolvingSymlinksInPath()
                if sessionDir.deletingLastPathComponent() == root, FileManager.default.fileExists(atPath: sessionDir.path) {
                    location = .init(session: latest, directory: sessionDir, project: directory)
                }
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    func markersDidChange() {
        guard let place = location, SessionMarkers.shared.sessionID == place.session.id else { return }
        Task {
            do {
                let next = try await ResearchCodebookStore.shared.update(place, .refresh)
                if location == place {
                    book = next
                }
            } catch {
                if location == place {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func retryProjectMerge() async {
        guard let place = location else { return }
        do {
            let next = try await ResearchCodebookStore.shared.update(place, .refresh)
            if location == place {
                book = next
            }
        } catch {
            if location == place {
                self.error = error.localizedDescription
            }
        }
    }

    func edit(_ edit: ResearchCodebook.Edit) async {
        guard let place = location else { return }
        if let preparation {
            await loadPrepared(preparation, at: place)
        }
        do {
            let next = try await ResearchCodebookStore.shared.update(place, .edit(edit))
            if location == place {
                book = next; error = nil
            }
        } catch {
            if location == place {
                self.error = error.localizedDescription
            }
        }
    }

    func star() async {
        guard let place = location, place.session.id == SessionCoordinator.shared.currentSessionId, SessionCoordinator.shared.isRunning else { return }
        let sources = GuideTranscript.liveSources()
        let source = selectedOffset.flatMap { offset in sources.min { abs($0.turn.startMs - offset) < abs($1.turn.startMs - offset) } } ?? sources.last
        guard let source else { return }
        do {
            try await ResearchCodebookStore.shared.star(Self.evidence(source, sessionID: place.session.id, group: place.session.group), in: place.directory)
            if location == place {
                error = nil; notice = "Starred line at \(GuideExtraction.locator(source.turn.startMs))."
            }
        } catch {
            if location == place {
                self.error = error.localizedDescription
            }
        }
    }
}
