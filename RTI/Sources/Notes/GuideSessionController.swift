import Foundation
import Observation
import RTICore

/// Owns one recording's frozen guide, navigation, and evidence. Manual and scheduled
/// Notes passes share the same committed-turn cursor; a late response cannot cross sessions.
@Observable @MainActor
final class GuideSessionController {
    static let shared = GuideSessionController()

    private(set) var guide: GuideDocument?
    private(set) var roster: [GuideSeat] = []
    private(set) var extraction: GuideExtraction?
    private(set) var isGenerating = false
    private(set) var lastError: String?

    var isActive: Bool {
        sessionID != nil
    }

    private(set) var manualQuestionID: String?
    private(set) var furthestIndex = 0
    var isFollowing: Bool { manualQuestionID == nil }

    /// Passed questions the moderator can still go back to: skipped once
    /// their section closed, or thinly covered. Newest first. Questions before
    /// the recording reached the guide are `notRecorded` and left out.
    /// Derived from the extraction on read; it adds no stored state and lags one pass.
    var gaps: [GuideGap] {
        gaps(includeNotRecorded: false)
    }

    /// `gaps`, optionally with the questions asked before the recording
    /// reached the guide (`notRecorded`), which the rail never shows.
    func gaps(includeNotRecorded: Bool) -> [GuideGap] {
        guard let guide, let extraction else { return [] }
        return GuideGaps.find(questions: guide.questions, cells: extraction.cells,
                              furthestIndex: furthestIndex, currentQID: currentQuestionID, rosterSize: rosterBase,
                              recordedFromIndex: recordedFromIndex, includeNotRecorded: includeNotRecorded)
    }

    /// A first position reached this early in the recording means the
    /// recording started mid-guide: questions before it were not recorded.
    static let lateStartWindowMs = 5 * 60 * 1000

    /// The first guide index the recording covers. 0 unless a position was
    /// first reached (selected, confirmed, or filed) within `lateStartWindowMs`
    /// and that first position sits in a later section (`GuideGaps.recordedFrom`):
    /// an early skip inside the first section is a real skip, not a late start.
    private var recordedFromIndex: Int {
        if let lateStartIndex { return lateStartIndex }
        guard let guide, let earliest = reached.values.min(), earliest <= Self.lateStartWindowMs else { return 0 }
        let filed = extraction?.cells.compactMap { cell in
            cell.coverage == "Not covered" ? nil : guide.questions.firstIndex { $0.qid == cell.qid }
        } ?? []
        return GuideGaps.recordedFrom(questions: guide.questions, firstReachedIndex: (Array(reached.keys) + filed).min())
    }

    /// The shared role rule's inputs for this session: the guide's wording
    /// and the speakers assigned to the moderator seat.
    var roleContext: TurnRoles.Context {
        let moderators = SpeakerNameStore.shared.guideSpeakers.filter(\.value.isModerator).keys
        return TurnRoles.Context(matcher: matcher, moderatorSpeakers: Set(moderators))
    }

    /// How long a guide position or a pass result stays fresh for Auto.
    static let autoFreshness: TimeInterval = 4 * 60

    /// The question Auto may name as the current one: the user's own pick,
    /// a marker link, or the last position a guide pass gave under four
    /// minutes ago. nil means the position is uncertain.
    func autoQuestion(at date: Date) -> GuideDocument.Question? {
        guard let guide else { return nil }
        let qid: String? = if let manualQuestionID {
            manualQuestionID
        } else if let linked = markerAt(Int.max)?.guideQuestionID {
            linked
        } else if let lastPosition, date.timeIntervalSince(lastPosition.at) < Self.autoFreshness {
            lastPosition.qid
        } else {
            nil
        }
        return qid.flatMap { id in guide.questions.first { $0.qid == id } }
    }

    /// Gaps for Auto, only while a guide pass succeeded in the last four minutes.
    func autoGaps(at date: Date) -> [GuideGap] {
        guard let lastPassAt, date.timeIntervalSince(lastPassAt) < Self.autoFreshness else { return [] }
        return gaps
    }

    #if DEBUG
        /// Tests only: record a successful pass, as `runPass` does.
        func notePassSucceededForTest(at date: Date, position: String? = nil) {
            lastPassAt = date
            if let position { lastPosition = (position, date) }
        }
    #endif

    var currentQuestionID: String? {
        manualQuestionID ?? markerAt(Int.max)?.guideQuestionID ?? cursor?.currentQID
    }

    func resolveMarker(label: String) -> String? {
        let answered = Set(extraction?.cells.filter { $0.coverage == "Answered" }.map(\.qid) ?? [])
        return guide?.resolveMarker(label, answered: answered)
    }

    @discardableResult
    func selectMarker(label: String, atMs ms: Int) -> String? {
        guard !sealed, let qid = markerAt(ms)?.guideQuestionID ?? resolveMarker(label: label) else { return nil }
        cursor?.select(qid, atMs: ms)
        updateProgress(qid)
        noteReached(qid, atMs: ms)
        return qid
    }

    private func markerAt(_ ms: Int) -> MarkerContext? {
        guard let sessionID, SessionMarkers.shared.sessionID == sessionID else { return nil }
        return SessionMarkers.shared.context(at: ms)
    }

    func questionID(atTranscriptMs ms: Int) -> String? {
        questionLookup.questionID(at: ms)
    }

    /// The guide question in effect at a transcript time, as a value: a
    /// checkpoint resolves its turns off main with it.
    struct QuestionLookup: Sendable {
        let hasGuide: Bool
        let selections: [Selection]
        /// nil when the markers belong to another session.
        let markers: MarkerTimeline?

        func questionID(at ms: Int) -> String? {
            guard hasGuide else { return nil }
            return locked(at: ms) ?? selections.last(where: { $0.transcriptMs <= ms })?.qid
        }

        func locked(at ms: Int) -> String? {
            let position = selections.last { $0.transcriptMs <= ms }
            let marker = markers?.context(at: ms)
            if let position, position.manual, position.transcriptMs >= (marker?.startMs ?? 0) { return position.qid }
            if let link = marker?.guideQuestionID { return link }
            guard let position, position.manual else { return nil }
            return position.qid
        }
    }

    var questionLookup: QuestionLookup {
        let owned = sessionID != nil && SessionMarkers.shared.sessionID == sessionID
        return QuestionLookup(hasGuide: guide != nil, selections: selections,
                              markers: owned ? SessionMarkers.shared.timeline : nil)
    }

    func markersDidChange() {
        guard let sessionID, SessionMarkers.shared.sessionID == sessionID, var updated = extraction else { return }
        let boundaries = SessionMarkers.shared.timeline.entries.filter { $0.kind == .marker }
        guard boundaries != markerBoundaries else { return }
        markerBoundaries = boundaries
        if let linked = markerAt(Int.max)?.guideQuestionID { updateProgress(linked) }
        updated.refile(speakers: SpeakerNameStore.shared.guideSpeakers, rosterBase: rosterBase, questionAt: lockedQuestion(at:))
        extraction = updated
    }

    private func updateProgress(_ qid: String) {
        if let index = guide?.questions.firstIndex(where: { $0.qid == qid }) { furthestIndex = max(furthestIndex, index) }
    }

    private func noteReached(_ qid: String, atMs ms: Int) {
        guard let index = guide?.questions.firstIndex(where: { $0.qid == qid }) else { return }
        reached[index] = min(reached[index] ?? ms, ms)
    }

    private func resetPassState() {
        lateStartIndex = nil
        reached = [:]
        lastPosition = nil
        lastPassAt = nil
        emptyStreak = 0
        backoffTicks = 0
        retryTurns = nil
        unfiled = []
    }

    func followLive(at date: Date = Date()) {
        guard !sealed, manualQuestionID != nil, let target = markerAt(Int.max)?.guideQuestionID ?? cursor?.currentQID else { return }
        manualQuestionID = nil
        let ms = max(0, Int(date.timeIntervalSince(startedAt) * 1000))
        appendSelection(target, atMs: ms, manual: false)
    }

    private var cursor: GuideCursor?
    /// The earliest guide index the user picked in the first
    /// `lateStartWindowMs` of the recording: they joined there, so every earlier question is
    /// `notRecorded`, never a skip, even inside the first section
    /// (2026-11-14: a group joined 25 minutes in listed warm-up as skipped).
    private var lateStartIndex: Int?
    /// A manual pick older than this lets a guide pass with evidence move the
    /// position again. A moderator line that reads another question moves it
    /// at once.
    static let manualHoldMs = 3 * 60 * 1000
    private(set) var matcher: GuideMatcher?
    /// Guide index -> earliest transcript ms the recording reached it.
    private var reached: [Int: Int] = [:]
    /// The last qid a pass gave as the position, and when.
    private var lastPosition: (qid: String, at: Date)?
    private var lastPassAt: Date?
    /// Consecutive decoded passes with nothing to file and no position.
    private(set) var emptyStreak = 0
    private var backoffTicks = 0
    /// A failed batch, retried once at its own size so a failure never
    /// doubles the next prompt. A second failure gives the batch up.
    private var retryTurns: Set<String>?
    /// Turns given up after two failed passes: never filed.
    private var unfiled: Set<String> = []
    private var sessionID: String?
    private var guideURL: URL?
    private var parsedSourceJSON: Data?
    private var rosterURL: URL?
    private var request: LLMRequest
    private var passRevision = 0
    private var consumed: Set<String> = []
    private var sealed = false
    private var startedAt = Date()

    /// Transcript time governs evidence assignment. Captured elapsed time governs
    /// the section clock, which excludes pauses even when a user revisits a section.
    struct Selection: Sendable {
        let qid: String
        let transcriptMs: Int
        let manual: Bool
    }

    private var selections: [Selection] = []
    private var markerBoundaries: [SessionNote] = []

    init(request: LLMRequest = LLMRequest(priority: .background)) {
        self.request = request
    }

    #if DEBUG
        /// The research replay drives the shared controller, which the
        /// codebook pass also reads, against recorded or scored replies.
        func useRequestForTest(_ request: LLMRequest) {
            self.request = request
        }
    #endif

    func startPreparedSession(_ sessionID: String, callType: CallType, startedAt: Date) {
        let prep = GuidePreparation.shared
        guard callType == .research, let guide = prep.guide, let url = prep.guideURL else {
            prep.reset()
            return
        }
        start(sessionID: sessionID, guide: guide, guideURL: url, group: prep.group, roster: prep.roster,
              rosterURL: prep.rosterURL, startedAt: startedAt, parsedSourceJSON: prep.parsedSourceJSON)
    }

    func start(sessionID: String, guide: GuideDocument, guideURL: URL, group: String?, roster: [GuideSeat],
               rosterURL: URL?, startedAt: Date = Date(), parsedSourceJSON: Data? = nil)
    {
        passRevision += 1
        self.sessionID = sessionID
        self.guide = guide
        self.guideURL = guideURL
        self.parsedSourceJSON = parsedSourceJSON
        self.startedAt = startedAt
        manualQuestionID = nil
        furthestIndex = 0
        markerBoundaries = []
        self.roster = roster
        self.rosterURL = rosterURL
        let cursor = GuideCursor(guide: guide)
        self.cursor = cursor
        matcher = GuideMatcher(guide: guide)
        resetPassState()
        extraction = GuideExtraction(group: group ?? "", transcript: "transcript.live.md", guide: guide)
        selections = [Selection(qid: cursor.currentQID, transcriptMs: 0, manual: false)]
        consumed.removeAll()
        sealed = false
        isGenerating = false
        lastError = nil
    }

    func endSession(_ id: String) {
        guard sessionID == id else { return }
        passRevision += 1
        request.cancel()
        sessionID = nil
        cursor = nil
        matcher = nil
        resetPassState()
        guide = nil
        guideURL = nil
        parsedSourceJSON = nil
        roster = []
        rosterURL = nil
        extraction = nil
        selections = []
        manualQuestionID = nil
        furthestIndex = 0
        markerBoundaries = []
        consumed.removeAll()
        isGenerating = false
        lastError = nil
        GuidePreparation.shared.reset()
    }

    func move(by distance: Int) {
        guard let guide, let qid = currentQuestionID,
              let index = guide.questions.firstIndex(where: { $0.qid == qid }) else { return }
        let next = index + distance
        guard guide.questions.indices.contains(next) else { return }
        jump(to: guide.questions[next].qid)
    }

    func jump(to qid: String) {
        guard SessionCoordinator.shared.isRunning else { return }
        select(qid, at: Date())
    }

    func select(_ qid: String, at date: Date) {
        guard !sealed, guide?.questions.contains(where: { $0.qid == qid }) == true else { return }
        let timeline = max(0, Int((date.timeIntervalSince(startedAt) * 1000).rounded()))
        cursor?.resetEvidence(atMs: timeline)
        manualQuestionID = qid
        if timeline <= Self.lateStartWindowMs, let index = guide?.questions.firstIndex(where: { $0.qid == qid }) {
            lateStartIndex = min(lateStartIndex ?? index, index)
        }
        appendSelection(qid, atMs: timeline, manual: true)
    }

    private func appendSelection(_ qid: String, atMs ms: Int, manual: Bool) {
        let index = selections.firstIndex { $0.transcriptMs > ms } ?? selections.endIndex
        selections.insert(Selection(qid: qid, transcriptMs: ms, manual: manual), at: index)
        updateProgress(qid)
        noteReached(qid, atMs: ms)
    }

    private func capturedElapsed(at date: Date) -> TimeInterval {
        let session = SessionCoordinator.shared
        if session.currentSessionId == sessionID {
            return session.capturedDuration(from: startedAt, through: date)
        }
        return max(0, date.timeIntervalSince(startedAt))
    }

    private var boundaryOffsets: [Int] {
        Set(selections.map(\.transcriptMs) + markerBoundaries.map(\.offsetMs)).sorted()
    }

    func visitNumber(for qid: String, at ms: Int) -> Int {
        var visits = 0
        var previous: String?
        for offset in boundaryOffsets where offset <= ms {
            let current = questionID(atTranscriptMs: offset)
            if current == qid && previous != qid { visits += 1 }
            previous = current
        }
        return max(1, visits)
    }

    func elapsed(in sectionID: String, at date: Date) -> TimeInterval {
        guard let section = guide?.sections.first(where: { $0.id == sectionID }) else { return 0 }
        let qids = Set(section.questions.map(\.qid))
        let end = capturedElapsed(at: date)
        let offsets = boundaryOffsets
        var total: TimeInterval = 0
        for (index, offset) in offsets.enumerated() {
            guard let qid = questionID(atTranscriptMs: offset), qids.contains(qid) else { continue }
            let begin = capturedElapsed(at: startedAt.addingTimeInterval(Double(offset) / 1000))
            let next = index + 1 < offsets.count
                ? capturedElapsed(at: startedAt.addingTimeInterval(Double(offsets[index + 1]) / 1000)) : end
            total += max(0, min(end, next) - begin)
        }
        return total
    }

    func remapSpeakers() {
        extraction?.remap(speakers: SpeakerNameStore.shared.guideSpeakers, rosterBase: rosterBase)
    }

    private var rosterBase: Int? {
        roster.isEmpty ? nil : roster.count
    }

    func snapshot(for id: String) -> GuideArchiveSnapshot? {
        guard sessionID == id, let guideURL, var extraction else { return nil }
        extraction.positions = selections.map { GuideExtraction.Position(qid: $0.qid, ms: $0.transcriptMs, manual: $0.manual) }
        if !sealed {
            let sources = GuideTranscript.liveSources()
            extraction.captureIncomplete = !unfiled.isEmpty || sources.contains { !consumed.contains($0.turn.id) }
        }
        return GuideArchiveSnapshot(extraction: extraction, guidePath: guideURL.path, rosterPath: rosterURL?.path,
                                    roster: roster, parsedSourceJSON: parsedSourceJSON)
    }

    static func sourceTurns(from entries: [LiveEntry]) -> [GuideTurn] {
        GuideTranscript.sources(from: entries).map(\.turn)
    }

    /// After this many empty passes in a row, the scheduler's ticks run
    /// only every third time until a pass files something again.
    static let backoffAfter = 3

    /// `explicit` is the "Write guide notes now" button: it skips the back-off.
    @discardableResult
    func generate(sessionId: String, entries: [LiveEntry], at date: Date = Date(), explicit: Bool = false) async -> Int? {
        await generate(sessionId: sessionId, at: date, explicit: explicit) { GuideTranscript.sources(from: entries) }
    }

    /// The live call's pass: its sources come from the coordinator's
    /// incremental utterance index (`GuideTranscript.liveSources`).
    @discardableResult
    func generateLive(sessionId: String, at date: Date = Date(), explicit: Bool = false) async -> Int? {
        await generate(sessionId: sessionId, at: date, explicit: explicit) { GuideTranscript.liveSources() }
    }

    private func generate(sessionId: String, at date: Date, explicit: Bool,
                          sources: () -> [GuideTranscript.Source]) async -> Int? {
        guard sessionID == sessionId, !isGenerating, !sealed else { return nil }
        let prepared = PassSignpost.interval("guide pass prep") { sources() }
        if !explicit, emptyStreak >= Self.backoffAfter {
            backoffTicks += 1
            if !backoffTicks.isMultiple(of: 3) {
                // A backed-off tick sends nothing, but a moderator line that
                // reads a new guide question still moves the position, and
                // a moved position ends the back-off: the talk moved on.
                guard movedByModerator(prepared, at: date) else { return nil }
                emptyStreak = 0
                backoffTicks = 0
            }
        }
        return await runPass(sources: prepared, at: date, deadline: nil)
    }

    /// A stop cancels queued periodic work. After Soniox's final delivery, take
    /// remaining batches under a single deadline, including a sub-interval recording.
    func finish(sessionId: String, entries: [LiveEntry], at date: Date = Date()) async {
        guard sessionID == sessionId, !sealed else { return }
        passRevision += 1
        request.cancel()
        sealed = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let sources = GuideTranscript.sources(from: entries)
        // Keep this true throughout the drain so an emergency quit halfway
        // through archives the committed prefix as incomplete.
        extraction?.captureIncomplete = true
        while ContinuousClock.now < deadline, !Task.isCancelled, sessionID == sessionId {
            guard await runPass(sources: sources, at: date, deadline: deadline) != nil else { break }
        }
        guard sessionID == sessionId else { return }
        let incomplete = !unfiled.isEmpty || sources.contains { !consumed.contains($0.turn.id) }
        extraction?.captureIncomplete = incomplete
        if incomplete {
            lastError = "Guide capture is incomplete. The transcript was kept."
        }
    }

    private func runPass(sources: [GuideTranscript.Source], at date: Date, deadline: ContinuousClock.Instant?) async -> Int? {
        guard let guide, cursor != nil else { return nil }
        let revision = passRevision
        let final = deadline != nil
        let pending = sources.filter { !consumed.contains($0.turn.id) }
        guard !pending.isEmpty else {
            isGenerating = false
            return nil
        }
        // A live utterance can still receive the next packet. Leave the recent
        // tail to the next pass; Finish processes it after Soniox has flushed.
        let latest = sources.map(\.endMs).max() ?? 0
        let session = SessionCoordinator.shared
        let end = session.currentSessionId == sessionID ? session.endedAt ?? date : date
        let observedMs = max(latest, Int(end.timeIntervalSince(startedAt) * 1000))
        let ready = pending.filter { final || $0.endMs <= observedMs - 2000 }
        guard !ready.isEmpty else { return nil }
        var newTurns = GuideTranscript.batch(ready)
        if let retry = retryTurns {
            let again = ready.filter { retry.contains($0.turn.id) }
            if again.isEmpty { retryTurns = nil } else { newTurns = again }
        }
        let context = sources.filter { $0.endMs >= observedMs - 90000 }
        // Mic-leg echoes of an in-room group are consumed but never sent.
        let echoes = GuideTranscript.echoIDs(newTurns + context, in: sources)
        let sentNew = newTurns.filter { !echoes.contains($0.turn.id) }
        let sentContext = context.filter { !echoes.contains($0.turn.id) }
        let roleContext = roleContext
        var roles: [String: SpeechRole] = [:]
        for source in sentNew + sentContext {
            roles[source.turn.id] = TurnRoles.role(speaker: source.turn.speaker, text: source.turn.text, context: roleContext)
        }
        let established = establishFromModerator(sentNew, roles: roles, at: date).established
        guard !sentNew.isEmpty, let cursor else {
            consumed.formUnion(newTurns.map(\.turn.id))
            retryTurns = nil
            return newTurns.last?.turn.startMs
        }
        let messages = GuidePrompt.messages(guide: guide, qid: cursor.currentQID, new: sentNew, context: sentContext,
                                            roles: roles, manualQID: lockedQuestion(at:))
        isGenerating = true
        defer {
            if revision == passRevision {
                isGenerating = false
            }
        }
        let response: String? = if let deadline {
            await GuidePrompt.collectFinal(messages: messages, request: request, deadline: deadline)
        } else {
            await request.collectAsync(messages: messages, smart: false)
        }
        guard revision == passRevision, !Task.isCancelled else { return nil }
        guard let response, let pass = GuidePrompt.decode(response) else {
            lastError = final ? "Guide capture is incomplete. The transcript was kept." : "Guide notes could not update. The next pass will retry."
            if final {
                extraction?.captureIncomplete = true
            } else if retryTurns == nil {
                retryTurns = Set(newTurns.map(\.turn.id))
            } else {
                // Second failure on the same batch: give it up so the next
                // prompt stays one batch long. The archive marks the gap.
                unfiled.formUnion(newTurns.map(\.turn.id))
                consumed.formUnion(newTurns.map(\.turn.id))
                retryTurns = nil
            }
            return nil
        }
        retryTurns = nil
        lastPassAt = date
        if pass.isEmpty, !established {
            emptyStreak += 1
        } else {
            emptyStreak = 0
            backoffTicks = 0
        }
        if !established, let suggestion = pass.suggestion, guide.questions.contains(where: { $0.qid == suggestion }) {
            lastPosition = (suggestion, date)
            let evidenceIDs = Set(pass.evidence)
            let evidence = sentContext.filter { $0.attributable && evidenceIDs.contains($0.turn.id) }.map(\.turn)
            if suggestion == self.cursor?.currentQID {
                if let first = evidence.map(\.startMs).min() { noteReached(suggestion, atMs: first) }
            } else if self.cursor?.suggest(suggestion, evidence: evidence, revision: cursor.revision) == true {
                let first = self.cursor?.acceptedFromMs ?? latest
                updateProgress(suggestion)
                if !isFollowing, let pick = selections.last(where: \.manual), first >= pick.transcriptMs + Self.manualHoldMs {
                    manualQuestionID = nil
                }
                if isFollowing { appendSelection(suggestion, atMs: first, manual: false) }
            }
        } else if !established {
            self.cursor?.suggest(cursor.currentQID, evidence: [], revision: cursor.revision)
        }
        // Moderator lines and bare backchannels (对对对 after a summary,
        // role unknown) never supply a quote or a note.
        let notEvidence = Set(roles.filter { $0.value != .respondent }.keys)
        fileEvidence(pass, from: sentNew.filter(\.attributable).map(\.turn), context: sentContext.map(\.turn),
                     moderatorTurns: notEvidence)
        consumed.formUnion(newTurns.map(\.turn.id))
        lastError = nil
        return newTurns.last?.turn.startMs
    }

    /// A moderator line that reads or closely paraphrases a guide question
    /// establishes that question on its own, anywhere in the guide. Every
    /// such line in the batch counts, in spoken order, so a batch that
    /// crosses two questions keeps both on the timeline (the replay found a
    /// backed-off pass that kept only the later one). A manual selection
    /// holds until a moderator line after it reads a different question:
    /// the room has moved on, so the pick is released. `established` is true when a line set or confirmed the
    /// position, `moved` when it set a new one.
    @discardableResult
    private func establishFromModerator(_ turns: [GuideTranscript.Source], roles: [String: SpeechRole],
                                        at date: Date) -> (established: Bool, moved: Bool) {
        guard let guide, let matcher, var current = manualQuestionID ?? cursor?.currentQID else { return (false, false) }
        var lastSelectionMs = selections.last?.transcriptMs ?? 0
        var established = false, moved = false
        for source in turns where roles[source.turn.id] == .moderator && source.turn.startMs >= lastSelectionMs {
            let currentIndex = guide.questions.firstIndex { $0.qid == current }
            guard let qid = matcher.question(asked: source.turn.text, near: currentIndex) else { continue }
            if !isFollowing {
                guard qid != manualQuestionID else { continue }
                manualQuestionID = nil
            }
            lastPosition = (qid, date)
            established = true
            if qid == current {
                noteReached(qid, atMs: source.turn.startMs)
            } else {
                cursor?.select(qid, atMs: source.turn.startMs)
                appendSelection(qid, atMs: source.turn.startMs, manual: false)
                current = qid
                lastSelectionMs = source.turn.startMs
                moved = true
            }
        }
        return (established, moved)
    }

    /// The local half of a pass on a backed-off tick: the ready turns' role
    /// hints and the moderator lines among them. Nothing is consumed.
    private func movedByModerator(_ sources: [GuideTranscript.Source], at date: Date) -> Bool {
        guard cursor != nil else { return false }
        let latest = sources.map(\.endMs).max() ?? 0
        let session = SessionCoordinator.shared
        let end = session.currentSessionId == sessionID ? session.endedAt ?? date : date
        let observedMs = max(latest, Int(end.timeIntervalSince(startedAt) * 1000))
        let ready = sources.filter { !consumed.contains($0.turn.id) && $0.endMs <= observedMs - 2000 }
        let context = roleContext
        var roles: [String: SpeechRole] = [:]
        for source in ready {
            roles[source.turn.id] = TurnRoles.role(speaker: source.turn.speaker, text: source.turn.text, context: context)
        }
        return establishFromModerator(ready, roles: roles, at: date).moved
    }

    /// A live pass and an offline fixture use the same timestamp routing and quote checks.
    /// `context` holds recent turns sent for context only: a tally count may
    /// rest on the moderator line just before it (`GuideExtraction.apply`).
    func fileEvidence(_ pass: GuidePass, from eligible: [GuideTurn], context: [GuideTurn] = [], moderatorTurns: Set<String> = []) {
        guard sessionID != nil else { return }
        let allowedQuestions = Dictionary(uniqueKeysWithValues: eligible.compactMap { turn in
            lockedQuestion(at: turn.startMs).map { (turn.id, $0) }
        })
        let routed = pass.routing { allowedQuestions[$0] }
        extraction?.apply(routed, turns: eligible, speakers: SpeakerNameStore.shared.guideSpeakers, rosterBase: rosterBase,
                          moderatorTurns: moderatorTurns, context: context) { qid, turn in
            allowedQuestions[turn].map { $0 == qid } ?? true
        }
        for cell in routed.cells {
            let times = cell.turns.compactMap { id in eligible.first { $0.id == id }?.startMs }
            if let first = times.min(), extraction?.cells.contains(where: { $0.qid == cell.qid && $0.coverage != "Not covered" }) == true {
                noteReached(cell.qid, atMs: first)
            }
        }
    }

    /// The question the user fixed for a transcript time: a manual
    /// selection or a marker link. An automatic position is only a hint, so
    /// a pass may file a turn anywhere in the guide.
    private func lockedQuestion(at ms: Int) -> String? {
        questionLookup.locked(at: ms)
    }
}
