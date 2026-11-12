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

    var currentQuestionID: String? {
        cursor?.currentQID
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
        let elapsed: TimeInterval
        let manual: Bool
    }

    private var selections: [Selection] = []

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
        self.roster = roster
        self.rosterURL = rosterURL
        let cursor = GuideCursor(guide: guide)
        self.cursor = cursor
        extraction = GuideExtraction(group: group ?? "", transcript: "transcript.live.md", guide: guide)
        selections = [Selection(qid: cursor.currentQID, transcriptMs: 0, elapsed: 0, manual: false)]
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
        cursor?.select(qid, atMs: timeline)
        selections.append(Selection(qid: qid, transcriptMs: timeline, elapsed: capturedElapsed(at: date), manual: true))
    }

    private func capturedElapsed(at date: Date) -> TimeInterval {
        let session = SessionCoordinator.shared
        if session.currentSessionId == sessionID {
            return session.capturedDuration(from: startedAt, through: date)
        }
        return max(0, date.timeIntervalSince(startedAt))
    }

    func elapsed(in sectionID: String, at date: Date) -> TimeInterval {
        guard let section = guide?.sections.first(where: { $0.id == sectionID }) else { return 0 }
        let qids = Set(section.questions.map(\.qid))
        let end = capturedElapsed(at: date)
        var total: TimeInterval = 0
        for (index, selection) in selections.enumerated() where qids.contains(selection.qid) {
            let next = selections.dropFirst(index + 1).first?.elapsed ?? end
            total += max(0, min(end, next) - selection.elapsed)
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
                let boundary = startedAt.addingTimeInterval(Double(first) / 1000)
                selections.append(Selection(qid: suggestion, transcriptMs: first, elapsed: capturedElapsed(at: boundary), manual: false))
            }
        } else {
            self.cursor?.suggest(cursor.currentQID, evidence: [], revision: cursor.revision)
        }
        let eligible = newTurns.filter(\.attributable).map(\.turn)
        let allowedQuestions = Dictionary(uniqueKeysWithValues: eligible.compactMap { turn in
            lockedQuestion(at: turn.startMs).map { (turn.id, $0) }
        })
        let routed = pass.routing { allowedQuestions[$0] }
        extraction?.apply(routed, turns: eligible, speakers: SpeakerNameStore.shared.guideSpeakers, rosterBase: rosterBase) { qid, turn in
            allowedQuestions[turn].map { $0 == qid } ?? true
        }
        consumed.formUnion(newTurns.map(\.turn.id))
        lastError = nil
        return newTurns.last?.turn.startMs
    }

    private func lockedQuestion(at ms: Int) -> String? {
        guard let selected = selections.last(where: { $0.transcriptMs <= ms }), selected.manual else { return nil }
        return selected.qid
    }
}
