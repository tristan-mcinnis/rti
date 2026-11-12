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

    /// Passed questions that were skipped or thinly covered, newest first.
    /// Derived from the extraction on read; it adds no stored state and lags one pass.
    var gaps: [GuideGap] {
        guard let guide, let extraction else { return [] }
        return GuideGaps.find(questions: guide.questions, cells: extraction.cells,
                              furthestIndex: furthestIndex, currentQID: currentQuestionID, rosterSize: rosterBase)
    }

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
        return qid
    }

    private func markerAt(_ ms: Int) -> MarkerContext? {
        guard let sessionID, SessionMarkers.shared.sessionID == sessionID else { return nil }
        return SessionMarkers.shared.context(at: ms)
    }

    func questionID(atTranscriptMs ms: Int) -> String? {
        guard guide != nil else { return nil }
        return lockedQuestion(at: ms) ?? selections.last(where: { $0.transcriptMs <= ms })?.qid
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

    func followLive(at date: Date = Date()) {
        guard !sealed, manualQuestionID != nil, let target = markerAt(Int.max)?.guideQuestionID ?? cursor?.currentQID else { return }
        manualQuestionID = nil
        let ms = max(0, Int(date.timeIntervalSince(startedAt) * 1000))
        appendSelection(target, atMs: ms, manual: false)
    }

    private var cursor: GuideCursor?
    private var sessionID: String?
    private var guideURL: URL?
    private var parsedSourceJSON: Data?
    private var rosterURL: URL?
    private let request: LLMRequest
    private var passRevision = 0
    private var consumed: Set<String> = []
    private var sealed = false
    private var startedAt = Date()

    /// Transcript time governs evidence assignment. Captured elapsed time governs
    /// the section clock, which excludes pauses even when a user revisits a section.
    private struct Selection {
        let qid: String
        let transcriptMs: Int
        let manual: Bool
    }

    private var selections: [Selection] = []
    private var markerBoundaries: [SessionNote] = []

    init(request: LLMRequest = LLMRequest(priority: .background)) {
        self.request = request
    }

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
        appendSelection(qid, atMs: timeline, manual: true)
    }

    private func appendSelection(_ qid: String, atMs ms: Int, manual: Bool) {
        let index = selections.firstIndex { $0.transcriptMs > ms } ?? selections.endIndex
        selections.insert(Selection(qid: qid, transcriptMs: ms, manual: manual), at: index)
        updateProgress(qid)
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
            let sources = GuideTranscript.sources(from: SessionCoordinator.shared.liveEntries)
            extraction.captureIncomplete = sources.contains { !consumed.contains($0.turn.id) }
        }
        return GuideArchiveSnapshot(extraction: extraction, guidePath: guideURL.path, rosterPath: rosterURL?.path,
                                    roster: roster, parsedSourceJSON: parsedSourceJSON)
    }

    static func sourceTurns(from entries: [LiveEntry]) -> [GuideTurn] {
        GuideTranscript.sources(from: entries).map(\.turn)
    }

    @discardableResult
    func generate(sessionId: String, entries: [LiveEntry], at date: Date = Date()) async -> Int? {
        guard sessionID == sessionId, !isGenerating, !sealed else { return nil }
        return await runPass(sources: GuideTranscript.sources(from: entries), at: date, deadline: nil)
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
        let incomplete = sources.contains { !consumed.contains($0.turn.id) }
        extraction?.captureIncomplete = incomplete
        if incomplete {
            lastError = "Guide capture is incomplete. The transcript was kept."
        }
    }

    private func runPass(sources: [GuideTranscript.Source], at date: Date, deadline: ContinuousClock.Instant?) async -> Int? {
        guard let guide, let cursor else { return nil }
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
        let newTurns = GuideTranscript.batch(ready)
        let context = sources.filter { $0.endMs >= observedMs - 90000 }
        let speakers = SpeakerNameStore.shared.guideSpeakers
        let messages = GuidePrompt.messages(guide: guide, qid: cursor.currentQID, new: newTurns,
                                            context: context, speakers: speakers, manualQID: lockedQuestion(at:))
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
            }
            return nil
        }
        if let suggestion = pass.suggestion {
            let evidenceIDs = Set(pass.evidence)
            let evidence = context.filter { $0.attributable && evidenceIDs.contains($0.turn.id) }.map(\.turn)
            if self.cursor?.suggest(suggestion, evidence: evidence, revision: cursor.revision) == true {
                let first = self.cursor?.acceptedFromMs ?? latest
                updateProgress(suggestion)
                if isFollowing { appendSelection(suggestion, atMs: first, manual: false) }
            }
        } else {
            self.cursor?.suggest(cursor.currentQID, evidence: [], revision: cursor.revision)
        }
        fileEvidence(pass, from: newTurns.filter(\.attributable).map(\.turn))
        consumed.formUnion(newTurns.map(\.turn.id))
        lastError = nil
        return newTurns.last?.turn.startMs
    }

    /// A live pass and an offline fixture use the same timestamp routing and quote checks.
    func fileEvidence(_ pass: GuidePass, from eligible: [GuideTurn]) {
        guard sessionID != nil else { return }
        let allowedQuestions = Dictionary(uniqueKeysWithValues: eligible.compactMap { turn in
            lockedQuestion(at: turn.startMs).map { (turn.id, $0) }
        })
        let routed = pass.routing { allowedQuestions[$0] }
        extraction?.apply(routed, turns: eligible, speakers: SpeakerNameStore.shared.guideSpeakers, rosterBase: rosterBase) { qid, turn in
            allowedQuestions[turn].map { $0 == qid } ?? true
        }
    }

    private func lockedQuestion(at ms: Int) -> String? {
        let position = selections.last { $0.transcriptMs <= ms }
        let marker = markerAt(ms)
        if let position, position.manual, position.transcriptMs >= (marker?.startMs ?? 0) { return position.qid }
        if let link = marker?.guideQuestionID { return link }
        guard let position, position.manual || position.transcriptMs > 0 else { return nil }
        return position.qid
    }
}
