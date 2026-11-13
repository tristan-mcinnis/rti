import Foundation
import Observation
import RTICore

/// Auto mode: each scheduler tick reads the transcript since its last pass and
/// proactively surfaces a few high-value cards — something to say, a question
/// to ask, a relevant fact to recall, or a flag. It is the always-on
/// counterpart to the manual Assist panel.
///
/// The call type frames each pass (`AutoAssistPrompt`): a client call steers
/// toward the pre-meeting brief's goal; a research session works from the
/// guide's gaps and current question and never sees the brief. Internal and
/// personal calls get no pass. Each pass acts on the new transcript only and
/// re-reads the three minutes before its watermark as context.
///
/// On by default for client and research calls; a toggle the user set wins
/// (`AutoAssistSettings.isActive`). Pass timing is one `AutoPassState` value:
/// debounce, floor (60 s on client calls, 150 s on research calls and 180 s
/// in a research group; the debounce and the scheduler tick both wait for
/// it, "Suggest now" skips it), and the busy
/// guard that the tick and "Suggest now" share, with the watermark that only
/// an accepted pass advances. A `LiveRailBoard` paces what the rail shows. When a project is picked
/// for the meeting, each pass first runs a project-scoped vault search keyed on
/// the new window so a card can cite what a participant actually said or what
/// a report concluded — the "they just asked about X, here's our answer" case.
/// That search uses `AutoVaultQuery` (a few salient terms, none for a short
/// window) and never leaves the project.
///
/// What a pass may show is checked in code (`AutoCardRules.accept`): a
/// RECALL needs a supplied source, a SAY or ASK in a Mandarin window needs
/// its Mandarin line, a card close to one shown in the last 15 minutes is a
/// repeat, and a research pass shows one card unless a contradiction comes
/// with it. A research pass is skipped while too little new respondent talk
/// arrived (`ResearchFormat.minimumRespondentCharacters`).
@Observable @MainActor
final class AutoAssistController {
    static let shared = AutoAssistController()

    private(set) var cards: [AutoAssistCard] = []
    private(set) var lastError: String?
    /// When the next pass may run. The one timing value; see `AutoPassState`.
    /// Not observed: every committed final moves its debounce deadline, and
    /// observing that re-ran the rail's body at the flush rate (2026-11-13 M1
    /// audit). Views read `isGenerating`, which changes only with the phase.
    @ObservationIgnored private(set) var pass = AutoPassState() {
        didSet {
            if isGenerating != pass.isGenerating { isGenerating = pass.isGenerating }
        }
    }
    /// What the live rail shows and when: each card's `new -> shown ->
    /// pinned | dismissed | expired` state, paced by `LiveRailPacer`.
    private(set) var rail = LiveRailBoard()
    /// A pass is running. Stored, and written only when it changes.
    private(set) var isGenerating = false
    /// When the user last spoke. Kept out of the observed `rail` so a mic
    /// final does not redraw the rail; copied in before each `advance`.
    @ObservationIgnored private var selfSpokeAt: Date?

    private let request: LLMRequest
    private let callTypes: CallTypeStore
    private let guide: GuideSessionController
    private let codebook: ResearchCodebookController
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var sessionId: String?
    /// The one timer `pass` asks for (debounce or floor), and the time it
    /// was armed for, on this controller's clock.
    @ObservationIgnored private var passTimer: Timer?
    @ObservationIgnored private var passTimerAt: Date?
    /// The one timer `rail` asks for (pacing, hold, fade).
    private var railTimer: Timer?
    /// A pass started by the debounce or floor timer. Stop cancels it.
    private var passTask: Task<Void, Never>?
    /// Set by `stop`: the rail admits nothing more until the next session.
    private var railStopped = false
    /// When Auto searches the project, the session's read files, and the
    /// last search's scope and result (reused between searches).
    @ObservationIgnored private var vaultCadence = AutoVaultCadence()
    @ObservationIgnored private var vaultCache = VaultSearch.DocumentCache()
    @ObservationIgnored private var lastVault: (scope: String, retrieval: VaultSearch.Retrieval)?
    /// The silence (by the system leg's last speech) a thin pass already ran for.
    @ObservationIgnored private var silencePassFor: Int?

    // Prompt defaults live in the registry (`PromptID.autoAssistCards` plus the
    // call-type framing), resolved through `PromptStore` so they're editable in
    // Settings and assembled by `AutoAssistPrompt`.

    /// Bumped on reset/clear so a pass still awaiting the LLM from an older
    /// session cannot write into the new one.
    private var generation: Int {
        pass.generation
    }

    /// `callTypes`, `guide`, `defaults` and `now` default to the shared
    /// stores and the wall clock; tests pass their own so a pass can be
    /// driven without a live call or the user's own Auto toggle.
    init(
        request: LLMRequest = LLMRequest(priority: .background),
        callTypes: CallTypeStore? = nil,
        guide: GuideSessionController? = nil,
        codebook: ResearchCodebookController? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.request = request
        self.callTypes = callTypes ?? .shared
        self.guide = guide ?? .shared
        self.codebook = codebook ?? .shared
        self.defaults = defaults
        self.now = now
    }

    /// Auto runs only on call types with a framing (client and research).
    var runsOnActiveCallType: Bool {
        AutoAssistPrompt.framing(for: callTypes.active) != nil
    }

    /// Auto is on for this call: the stored toggle, or the call type's
    /// default when the user never set one, and a call type that has Auto.
    /// The tab, menu and switches use the same `AutoAssistSettings.isActive`.
    var isActiveForCall: Bool {
        AutoAssistSettings.isActive(for: callTypes.active, defaults: defaults) && runsOnActiveCallType
    }

    static let offCallTypeMessage = "Auto runs on client and research calls only."

    /// A group, an interview or not known, from the guide's roster and
    /// title. It sets the research floor and the thin-input bar.
    var researchFormat: ResearchFormat {
        guard guide.isActive else { return .unknown }
        return ResearchFormat.infer(rosterCount: guide.roster.count, guideTitle: guide.guide?.title)
    }

    private var floor: TimeInterval {
        AutoPassState.floor(for: callTypes.active, format: researchFormat) ?? AutoPassState.floor(for: .client) ?? 60
    }

    /// Bind to a session and drop any prior cards.
    func reset(for sessionId: String) {
        clearState()
        self.sessionId = sessionId
    }

    func clear() {
        clearState()
        sessionId = nil
    }

    private func clearState() {
        passTask?.cancel()
        passTask = nil
        vaultCadence = AutoVaultCadence()
        vaultCache = VaultSearch.DocumentCache()
        lastVault = nil
        silencePassFor = nil
        apply(pass.reduce(.reset, now: now(), floor: floor))
        lastError = nil
        cards = []
        rail.reset()
        railStopped = false
        selfSpokeAt = nil
        railTimer?.invalidate()
        railTimer = nil
    }

    /// The recording stopped. Drop any waiting or running pass (its reply is
    /// discarded) and stop the rail from admitting more cards. The cards
    /// already surfaced stay readable until the next session resets them.
    func stop() {
        passTask?.cancel()
        passTask = nil
        apply(pass.reduce(.stop, now: now(), floor: floor))
        railStopped = true
        railTimer?.invalidate()
        railTimer = nil
    }

    func pin(_ id: UUID) {
        rail.pin(id)
    }

    /// A dismissed card never comes back, even if a later pass repeats it.
    func dismiss(_ id: UUID) {
        rail.dismiss(id)
        advanceRail()
    }

    #if DEBUG
        /// Render proofs only: put these cards on the rail as if each pass had
        /// returned at its time, oldest first, through the same pacer.
        func seedRailForRenderProof(_ seeded: [(card: AutoAssistCard, at: Date)], callType: CallType) {
            clearState()
            for (card, at) in seeded.sorted(by: { $0.at < $1.at }) {
                cards.append(card)
                rail.offer([LiveRailItem(id: card.id, text: card.text, lane: card.kind == .flag ? .threads : .now, arrivedAt: at)])
                rail.advance(now: at, callType: callType)
            }
        }
    #endif

    // MARK: - Proactive triggering

    /// Called when new final transcript content lands. Debounces, then fires a
    /// pass once talk has settled — subject to the per-pass floor. Cheap to call
    /// on every committed line; no-ops when Auto is off or no session runs.
    /// `currentSessionId` outlives the recording (it is replaced only by the
    /// next start), so "a session runs" is `isRunning`: finals flushed in the
    /// stop window, or a debounce armed just before Stop, otherwise ran one
    /// more paid pass after the scheduler had already stopped.
    /// `selfSpoke` is true when the newest final came from the user's own mic;
    /// the rail holds new cards briefly while the user talks on a client call.
    func noteActivity(selfSpoke: Bool = false) {
        guard SessionCoordinator.shared.isRunning, isActiveForCall else { return }
        if selfSpoke {
            selfSpokeAt = now()
        }
        apply(pass.reduce(.activity, now: now(), floor: floor))
    }

    /// The armed timer fired: run a pass if the debounce and the floor have
    /// passed, otherwise wait for them. If Auto was turned off or the
    /// recording ended meanwhile, the waiting pass is dropped. Internal so a
    /// test can fire it on its own clock.
    func timerFired() {
        guard SessionCoordinator.shared.isRunning, isActiveForCall else {
            apply(pass.reduce(.cancelPending, now: now(), floor: floor))
            return
        }
        apply(pass.reduce(.timerFired, now: now(), floor: floor))
    }

    /// Apply one effect from `pass`: the one timer, or a pass.
    private func apply(_ effect: AutoPassState.Effect) {
        switch effect {
        case .none:
            return
        case .disarm:
            passTimer?.invalidate()
            passTimer = nil
        case let .arm(at):
            // A timer that fires at or before `at` may stay: `pass` re-arms
            // when it fires early. So a burst of finals re-arms about once
            // per quiet window, not once per flush.
            if let passTimer, passTimer.isValid, let armed = passTimerAt, armed <= at,
               at.timeIntervalSince(armed) < AutoPassState.quietWindow {
                return
            }
            passTimer?.invalidate()
            passTimerAt = at
            passTimer = Timer.scheduledTimer(withTimeInterval: max(0, at.timeIntervalSince(now())), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.timerFired() }
            }
        case let .startPass(passGeneration):
            passTimer?.invalidate()
            passTimer = nil
            guard let sid = SessionCoordinator.shared.currentSessionId else {
                apply(pass.reduce(.passFinished(generation: passGeneration, endMs: nil), now: now(), floor: floor))
                return
            }
            passTask = Task { @MainActor [weak self] in _ = await self?.run(sessionId: sid, generation: passGeneration) }
        }
    }

    /// Surface cards over the transcript since the last pass. Used by both the
    /// periodic scheduler and the manual button. The scheduler tick waits
    /// for the floor like the debounce does. `explicit` is the button: the
    /// user asked, so the pass skips the floor and the rail shows its first
    /// card at once instead of waiting out the pacer's spacing.
    @discardableResult
    func generate(sessionId: String, explicit: Bool = false) async -> Int? {
        let event: AutoPassState.Event = explicit ? .passRequested : .tick
        guard case let .startPass(passGeneration) = pass.reduce(event, now: now(), floor: floor) else {
            return nil
        }
        passTimer?.invalidate()
        passTimer = nil
        return await run(sessionId: sessionId, generation: passGeneration, explicit: explicit)
    }

    /// One pass that `pass` has already admitted as `generating`. Every exit
    /// reports back, so the busy state is always released by its owner.
    private func run(sessionId: String, generation passGeneration: Int, explicit: Bool = false) async -> Int? {
        lastError = nil
        var endMs: Int?
        var skipped = false
        defer {
            let event: AutoPassState.Event = skipped
                ? .passSkipped(generation: passGeneration)
                : .passFinished(generation: passGeneration, endMs: endMs)
            apply(pass.reduce(event, now: now(), floor: floor))
        }
        // A research pass waits for enough new respondent talk. It sends
        // nothing, keeps the watermark and gives back its floor, so the
        // next settled final (7 s debounce) or tick checks the window again.
        // A silent system leg is the exception: the silence signal is the
        // news, and with no respondent talk the thin rule would hold it back
        // until the room came back (the 2026-11-13 replay). One pass per
        // silence.
        if !explicit, callTypes.active == .research, !hasEnoughRespondentTalk(since: pass.watermarkMs) {
            let silentSince = silentThemSince()
            guard let silentSince, silentSince != silencePassFor else {
                skipped = true
                return nil
            }
            silencePassFor = silentSince
        }
        guard let prepared = await preparePass(sessionId: sessionId, windowStartMs: pass.watermarkMs,
                                               generation: passGeneration)
        else { return nil }

        guard let response = await request.collectAsync(
            messages: [LLMMessage(role: "user", content: prepared.prompt)], smart: false
        ), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard pass.owns(generation: passGeneration) else { return nil }

        let items = JSONExtractor.decodeArrayLenient(response, key: "cards", as: AutoCardItem.self)
        // Drop exact repeats of cards the user saw or that still wait on the
        // rail. A card that faded unseen may come back. Then the code rules:
        // source, Mandarin line, near repeats, one card per research pass.
        rail.fade(now: now())
        var seen = Set<String>()
        let decoded: [AutoAssistCard] = items.compactMap { item in
            guard let card = AutoAssistCard.make(from: item, citations: prepared.citations),
                  !rail.repeatsKnownItem(card.text),
                  seen.insert(LiveRailPacer.normalized(card.text)).inserted else { return nil }
            return card
        }
        let fresh = AutoCardRules.accept(decoded, callType: callTypes.active, mandarin: prepared.mandarin,
                                         recent: recentCards, guideActive: guide.isActive)
        cards.append(contentsOf: fresh)
        if cards.count > 300 { cards.removeFirst(cards.count - 300) }
        // One arrival time per pass, so the pacer keeps the model's order
        // within a pass and puts a newer pass first.
        let arrivedAt = now()
        rail.offer(fresh.map {
            LiveRailItem(id: $0.id, text: $0.text, lane: $0.kind == .flag ? .threads : .now, arrivedAt: arrivedAt)
        })
        advanceRail(explicit: explicit)
        // Only advance the watermark once the LLM response has been accepted.
        endMs = prepared.endMs
        return prepared.endMs
    }

    /// Cards the user saw on the rail, oldest first. The next pass is told
    /// not to repeat these; a card the pacer never showed is not on the list.
    var surfacedCards: [AutoAssistCard] {
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rail.surfaced.compactMap { byID[$0.id] }
    }

    /// Cards shown in the last 15 minutes or still waiting: a new card close
    /// to one of these is a repeat (`AutoCardRules.isRepeat`).
    private var recentCards: [AutoAssistCard] {
        let since = now().addingTimeInterval(-AutoCardRules.repeatWindow)
        let ids = Set(rail.items.filter { item in
            item.state == .new || (item.shownAt.map { $0 >= since } ?? false)
        }.map(\.id))
        return cards.filter { ids.contains($0.id) }
    }

    /// When the system leg last spoke, while it has been silent long enough
    /// for the silence signal (`AutoResearchSignals.silenceMs`); else nil.
    private func silentThemSince() -> Int? {
        let last = TranscriptContext.lastSpeech()
        return AutoResearchSignals.silence(lastThemMs: last.them, latestMs: last.any) == nil ? nil : last.them
    }

    /// Enough new respondent talk since `watermarkMs` for a research pass.
    func hasEnoughRespondentTalk(since watermarkMs: Int) -> Bool {
        let characters = TranscriptContext.respondentCharacters(sinceMs: watermarkMs == 0 ? nil : watermarkMs,
                                                                roles: guide.roleContext)
        return characters >= researchFormat.minimumRespondentCharacters
    }

    /// Let the pacer admit, fade and cap, then arm the one rail timer.
    private func advanceRail(explicit: Bool = false) {
        railTimer?.invalidate()
        railTimer = nil
        guard !railStopped else { return }
        if let selfSpokeAt, rail.selfSpokeAt != selfSpokeAt {
            rail.noteSelfSpeech(at: selfSpokeAt)
        }
        guard let next = rail.advance(now: now(), callType: callTypes.active, explicit: explicit) else { return }
        railTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, next.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceRail() }
        }
    }

    /// One pass's prompt, plus the watermark to apply once the reply is
    /// accepted and the citations its cards may use.
    struct Pass {
        let prompt: String
        let endMs: Int
        let citations: [VaultSearch.Citation]
        /// More than 30% of the new window is CJK.
        var mandarin = false
    }

    /// Gathers one pass's inputs from live state and builds its prompt. nil
    /// when the call type has no Auto (with a short `lastError`, so a manual
    /// press explains itself), when nothing new was said, or when a reset
    /// overtook the vault search. `windowStartMs` is the watermark: the new
    /// window is everything after it; the context window is the
    /// `AutoAssistPrompt.contextWindowMs` up to and including it.
    func preparePass(sessionId: String, windowStartMs: Int, generation passGeneration: Int) async -> Pass? {
        let callType = callTypes.active
        guard AutoAssistPrompt.framing(for: callType) != nil else {
            lastError = Self.offCallTypeMessage
            return nil
        }
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs
        // Research lines carry the shared role hint (`TurnRoles`), split at
        // question marks, with mic-leg echoes of an in-room group removed.
        let roles: TurnRoles.Context? = callType == .research ? guide.roleContext : nil
        // The minutes already covered, re-read as context only. A lower
        // bound at or before the start means "from the start": the filter is
        // exclusive, so 0 would drop a line spoken at 0 ms.
        let (recentContext, window, endMs) = PassSignpost.interval("auto pass prep") { () -> (String?, String, Int) in
            let recentContext: String? = sinceMs.map { watermark in
                let lower = watermark - AutoAssistPrompt.contextWindowMs
                return TranscriptContext.text(forSessionId: sessionId, sinceMs: lower > 0 ? lower : nil, untilMs: watermark,
                                              hoistNotes: false, roles: roles)
            }.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            // The evidence rule goes once, with the first transcript section.
            let window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs, hoistNotes: false,
                                                evidenceRule: recentContext == nil, roles: roles)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Compute the watermark but DO NOT apply it until the LLM call succeeds.
            // If the request fails or returns empty, we want to retry this window
            // rather than permanently skip it.
            let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? windowStartMs
            return (recentContext, window, endMs)
        }
        guard !window.isEmpty else { return nil }

        // Project-scoped retrieval: pull what the project's vault knows about
        // what's being discussed right now, so a RECALL card can be real. Only
        // when a project is picked (scope present) — keeps generic meetings cheap.
        // The query is the new window's 12 most salient terms, and a window
        // under 25 words searches nothing. The search stays in the project:
        // it never widens to the whole vault (`search_vault` still does).
        let meeting = MeetingContextStore.shared
        var vaultMaterial: String?
        var citations: [VaultSearch.Citation] = []
        // The search runs at `.utility` on two workers for at most 300 ms
        // (`VaultSearch.Budget.auto`), reads each file once per session
        // (`vaultCache`), and runs at most once every three passes
        // (`AutoVaultCadence`); the passes between reuse its hit.
        if let scope = meeting.workstreamScopePath,
           let query = AutoVaultQuery.query(from: TranscriptContext.spokenText(sinceMs: sinceMs)) {
            if vaultCadence.shouldSearch() || lastVault?.scope != scope {
                let found = await VaultSearch.retrieve(query: query, scopeRelativePath: scope, citeable: true,
                                                       broaden: false, budget: .auto, cache: vaultCache)
                guard passGeneration == generation else { return nil }
                lastVault = (scope, found)
            }
            // Only inject a genuine hit, not the "nothing matched" sentinel.
            if let found = lastVault?.retrieval, !found.isEmpty {
                vaultMaterial = found.formatted
                citations = found.citations
            }
        }

        // A guide position goes in only while fresh: the user's pick, a
        // marker link, or a guide pass under four minutes old. Gaps go in
        // only while a guide pass succeeded in the last four minutes.
        let guideActive = callType == .research && guide.isActive
        let question = guideActive ? guide.autoQuestion(at: now()) : nil
        let currentQuestion = question.map { [$0.qid, $0.en, $0.zh].filter { !$0.isEmpty }.joined(separator: " / ") }
        let surfaced = surfacedCards
        let older = surfaced.dropLast(AutoAssistPrompt.priorLimit).suffix(30)
        let mandarin = AutoCardLanguage.isMandarin(TranscriptContext.spokenText(sinceMs: sinceMs))
        let prompts = PromptStore.shared
        guard let prompt = AutoAssistPrompt.build(
            callType: callType,
            brief: meeting.briefContext,
            projectContext: meeting.combined,
            gaps: guideActive ? guide.autoGaps(at: now()) : [],
            currentQuestion: currentQuestion,
            guidePositionUncertain: guideActive && currentQuestion == nil,
            sectionBudgets: guideActive ? guide.guide.map(AutoResearchSignals.budgets) ?? [] : [],
            prior: surfaced.suffix(AutoAssistPrompt.priorLimit).map { "- [\($0.kind.rawValue)] \($0.text)" },
            priorTopics: older.isEmpty ? nil : older.map { Self.topic($0.text) }.joined(separator: "; "),
            codes: callType == .research ? codebookLines() : [],
            signals: callType == .research ? researchSignals(question: guideActive ? question : nil) : [],
            userNotes: TranscriptContext.userNotes(),
            vault: vaultMaterial,
            recentContext: recentContext,
            mandarin: mandarin,
            newWindow: window,
            resolve: { prompts.text($0) }
        ) else { return nil }
        return Pass(prompt: prompt, endMs: endMs, citations: citations, mandarin: mandarin)
    }

    /// The first six words of an older card, for the one topic line.
    static func topic(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return String(text.prefix(16)) }
        return words.prefix(6).joined(separator: " ")
    }

    /// The codebook's top 10 tensions and hypotheses for this call, with
    /// quote counts. Only while the codebook follows this recording.
    private func codebookLines() -> [String] {
        guard let place = codebook.location, place.session.id == SessionCoordinator.shared.currentSessionId else { return [] }
        let topics = codebook.book.topicMap(sessionID: place.session.id, limit: 60).sections
            .filter { $0.group == .tensions || $0.group == .hypotheses }
            .flatMap(\.topics)
            .sorted { ($0.type == .tension ? $0.mentions : $0.support + $0.against) > ($1.type == .tension ? $1.mentions : $1.support + $1.against) }
            .prefix(10)
        return topics.map { topic in
            let name = [topic.name, topic.gloss].compactMap(\.self).joined(separator: " / ")
            if topic.type == .tension {
                let sides = topic.sides.map { "\(ResearchTopic.Side.clock($0.offsetMs)) 「\($0.words)」" }.joined(separator: " vs ")
                return "- Tension: \(name) (\(topic.mentions) quotes)" + (sides.isEmpty ? "" : ": \(sides)")
            }
            return "- Hypothesis: \(name): \(topic.support) for, \(topic.against) against"
        }
    }

    /// Facts the model should not have to work out: the current section ran
    /// past its budget, or the other side has been silent for 3 minutes.
    private func researchSignals(question: GuideDocument.Question?) -> [String] {
        var signals: [String] = []
        if let question, let document = guide.guide,
           let section = document.sections.first(where: { $0.questions.contains { $0.qid == question.qid } })
        {
            let answered = Set(guide.extraction?.cells.filter { $0.coverage == "Answered" }.map(\.qid) ?? [])
            let open = section.questions.filter { !answered.contains($0.qid) && !GuideMatcher.isInstruction($0) }.map(\.qid)
            if let overrun = AutoResearchSignals.overrun(section: section, elapsed: guide.elapsed(in: section.id, at: now()),
                                                         openQIDs: open)
            {
                signals.append(overrun)
            }
        }
        let last = TranscriptContext.lastSpeech()
        if let silence = AutoResearchSignals.silence(lastThemMs: last.them, latestMs: last.any) {
            signals.append(silence)
        }
        return signals
    }
}
