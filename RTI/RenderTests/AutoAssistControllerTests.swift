import RTICore
import XCTest

/// The controller's side of an Auto pass: which call types run, what it reads
/// from the brief, the project context and the guide, and how it splits the
/// transcript at its watermark into context and new talk.
@MainActor
final class AutoAssistControllerTests: RenderProofTestCase {
    private let session = "auto-fixture"

    override func tearDown() async throws {
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        MeetingContextStore.shared.seedBriefForRenderProof(nil)
        MeetingContextStore.shared.note = ""
        try await super.tearDown()
    }

    private func entry(_ speaker: String, _ text: String, _ start: Int) -> LiveEntry {
        LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1,
                  translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    private func seed(_ entries: [LiveEntry]) {
        SessionCoordinator.shared.seedForRenderProof(entries: entries, interim: nil, phase: .recording, startedAt: Date())
    }

    private func controller(_ callType: CallType, guide: GuideSessionController = GuideSessionController()) -> AutoAssistController {
        AutoAssistController(callTypes: .inMemory(callType), guide: guide)
    }

    private func unwrapPass(_ auto: AutoAssistController, from watermark: Int) async throws -> AutoAssistController.Pass {
        let pass = await auto.preparePass(sessionId: session, windowStartMs: watermark, generation: 0)
        return try XCTUnwrap(pass)
    }

    private func activeGuide() throws -> GuideSessionController {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let document = try GuideDocument.parse(Data(contentsOf: url))
        let guide = GuideSessionController()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        guide.start(sessionID: "auto-guide-fixture", guide: document, guideURL: url, group: nil, roster: [],
                    rosterURL: nil, startedAt: start)
        guide.select("S2Q1", at: start.addingTimeInterval(20))
        XCTAssertFalse(guide.gaps.isEmpty)
        return guide
    }

    // MARK: - TranscriptContext windows

    func testUntilMsBoundaryPutsTheWatermarkLineInContextOnly() {
        seed([entry("remote", "Opening.", 1000), entry("remote", "At the watermark.", 2000), entry("self", "After it.", 3000)])
        let context = TranscriptContext.text(forSessionId: session, untilMs: 2000)
        let fresh = TranscriptContext.text(forSessionId: session, sinceMs: 2000)
        XCTAssertTrue(context.contains("Opening.") && context.contains("At the watermark."))
        XCTAssertFalse(context.contains("After it."))
        XCTAssertTrue(fresh.contains("After it."))
        XCTAssertFalse(fresh.contains("At the watermark."))
    }

    func testEvidenceRuleAndNotesHeaderCanBeLeftOut() {
        seed([entry("remote", "Hello.", 1000), entry("note", "Budget is fixed", 1500)])
        let full = TranscriptContext.text(forSessionId: session)
        XCTAssertTrue(full.contains("Me and Them identify audio inputs"))
        XCTAssertTrue(full.contains("## User notes"))
        let bare = TranscriptContext.text(forSessionId: session, hoistNotes: false, evidenceRule: false)
        XCTAssertFalse(bare.contains("Me and Them identify audio inputs"))
        XCTAssertFalse(bare.contains("## User notes"))
        XCTAssertTrue(bare.contains("[user note]] Budget is fixed"), "the note stays inline: \(bare)")
        XCTAssertEqual(TranscriptContext.userNotes(), ["Budget is fixed"])
    }

    // MARK: - Call types

    func testInternalAndPersonalExplainThemselvesAndBuildNothing() async {
        seed([entry("remote", "Anything new.", 1000)])
        for callType in [CallType.internal, .personal] {
            let auto = controller(callType)
            XCTAssertFalse(auto.runsOnActiveCallType)
            let pass = await auto.preparePass(sessionId: session, windowStartMs: 0, generation: 0)
            XCTAssertNil(pass)
            XCTAssertEqual(auto.lastError, AutoAssistController.offCallTypeMessage)
            let generated = await auto.generate(sessionId: session)
            XCTAssertNil(generated)
            XCTAssertEqual(auto.lastError, AutoAssistController.offCallTypeMessage, "the manual button explains a no-op")
        }
        XCTAssertTrue(controller(.client).runsOnActiveCallType)
        XCTAssertTrue(controller(.research).runsOnActiveCallType)
    }

    // MARK: - Inputs

    func testClientReadsTheBriefFromBriefContextAndTheProjectFromCombined() async throws {
        seed([entry("remote", "When do we launch?", 1000)])
        MeetingContextStore.shared.seedBriefForRenderProof("BRIEF_FIXTURE lock the launch date")
        MeetingContextStore.shared.note = "NOTE_FIXTURE project facts"
        let guide = try activeGuide()
        let pass = try await unwrapPass(controller(.client, guide: guide), from: 0)
        XCTAssertTrue(pass.prompt.contains("Pre-meeting brief (the goal of this call; steer toward it):\n---\nBRIEF_FIXTURE lock the launch date\n---"))
        XCTAssertTrue(pass.prompt.contains("This meeting's project context (treat as ground truth):\n---\nNOTE_FIXTURE project facts"))
        XCTAssertFalse(pass.prompt.contains("Guide gaps"), "a client call gets no guide even when one runs")
        XCTAssertFalse(pass.prompt.contains("Current guide question"))
        XCTAssertEqual(pass.endMs, 1000)
    }

    func testResearchGetsGapsAndQuestionOnlyFromAnActiveGuideAndNeverTheBrief() async throws {
        seed([entry("remote", "I just buy whatever.", 1000)])
        MeetingContextStore.shared.seedBriefForRenderProof("BRIEF_FIXTURE")
        let guide = try activeGuide()
        let active = try await unwrapPass(controller(.research, guide: guide), from: 0)
        XCTAssertFalse(active.prompt.contains("BRIEF_FIXTURE"))
        XCTAssertTrue(active.prompt.contains("Guide gaps"))
        XCTAssertTrue(active.prompt.contains("- [S1Q2]"))
        XCTAssertTrue(active.prompt.contains("Current guide question:\n"))

        let idle = try await unwrapPass(controller(.research), from: 0)
        XCTAssertFalse(idle.prompt.contains("Guide gaps"))
        XCTAssertFalse(idle.prompt.contains("Current guide question"))
    }

    // MARK: - Watermark split

    func testWatermarkSplitsContextFromNewTalkAndKeepsALineAtZero() async throws {
        seed([entry("remote", "Line at zero.", 0), entry("remote", "At the watermark.", 2000),
              entry("self", "Fresh question?", 3000), entry("note", "Typed early", 500)])
        let pass = try await unwrapPass(controller(.client), from: 2000)
        let context = try XCTUnwrap(pass.prompt.range(of: "Earlier conversation (context only; do not make cards about it):\n"))
        let fresh = try XCTUnwrap(pass.prompt.range(of: "New conversation since the last pass (act on this):\n"))
        let contextText = String(pass.prompt[context.upperBound ..< fresh.lowerBound])
        let freshText = String(pass.prompt[fresh.upperBound...])
        XCTAssertTrue(contextText.contains("Line at zero."), "a watermark under 3 minutes reads from the start")
        XCTAssertTrue(contextText.contains("At the watermark."))
        XCTAssertFalse(contextText.contains("Fresh question?"))
        XCTAssertTrue(freshText.contains("Fresh question?"))
        XCTAssertFalse(freshText.contains("At the watermark."))
        XCTAssertEqual(pass.endMs, 3000)
        XCTAssertEqual(pass.prompt.components(separatedBy: "Me and Them identify audio inputs").count, 2, "the evidence rule appears once")
        XCTAssertFalse(pass.prompt.contains("## User notes"), "no notes header inside a transcript window")
        XCTAssertTrue(pass.prompt.contains("Notes the user typed during this call (authoritative; trust them over the transcript):\n- Typed early"))
    }

    func testContextWindowStopsThreeMinutesBeforeTheWatermark() async throws {
        seed([entry("remote", "Too old.", 10000), entry("remote", "Recent enough.", 30000),
              entry("remote", "At the watermark.", 200_000), entry("self", "New.", 250_000)])
        let pass = try await unwrapPass(controller(.research), from: 200_000)
        XCTAssertFalse(pass.prompt.contains("Too old."))
        XCTAssertTrue(pass.prompt.contains("Recent enough."))
        XCTAssertTrue(pass.prompt.contains("At the watermark."))
    }

    func testFirstPassHasNoContextAndNothingNewSkips() async throws {
        seed([entry("remote", "Only line.", 1000)])
        let auto = controller(.client)
        let first = try await unwrapPass(auto, from: 0)
        XCTAssertFalse(first.prompt.contains("context only"))
        XCTAssertEqual(first.prompt.components(separatedBy: "Me and Them identify audio inputs").count, 2)
        let none = await auto.preparePass(sessionId: session, windowStartMs: 1000, generation: 0)
        XCTAssertNil(none)
        XCTAssertNil(auto.lastError)
    }

    // MARK: - Effect wiring: timer, busy state, stop, badge and rail

    private nonisolated static let twoCards = """
    {"cards":[{"kind":"ask","text":"Ask who signs off","why":"Nobody named an owner."},
    {"kind":"say","text":"Say the renewal is in March","why":"They asked when."}]}
    """

    /// Clock, Auto toggle store, and a recording session the controller can see.
    private final class Rig {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = "AutoAssistControllerTests.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func liveController(_ rig: Rig, request: LLMRequest, callType: CallType = .client) -> AutoAssistController {
        AutoAssistController(request: request, callTypes: .inMemory(callType), guide: GuideSessionController(),
                             defaults: rig.defaults, now: { rig.clock })
    }

    private func startRecording(_ entries: [LiveEntry]) {
        SessionCoordinator.shared.beginTranscriptReplayForProof()
        seed(entries)
    }

    private func stopRecording() {
        SessionCoordinator.shared.endTranscriptReplayForProof()
    }

    private func waitUntilIdle(_ auto: AutoAssistController) async {
        var tries = 0
        while auto.isGenerating, tries < 500 {
            tries += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testDebounceTimerRunsAPassThatReleasesBusyAndFeedsTheRail() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal?", 1000), entry("remote", "Who approves it?", 4000)])
        defer { stopRecording() }
        let calls = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await calls.bump()
            return LLMClient.CollectedResponse(text: Self.twoCards, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        XCTAssertTrue(auto.isActiveForCall, "unset toggle: Auto is on for a client call")

        auto.noteActivity()
        XCTAssertEqual(auto.pass.phase, .debouncing(until: rig.clock.addingTimeInterval(AutoPassState.quietWindow)))
        auto.timerFired()
        XCTAssertFalse(auto.isGenerating, "the debounce has not passed yet")

        rig.clock = rig.clock.addingTimeInterval(AutoPassState.quietWindow + 1)
        auto.timerFired()
        XCTAssertTrue(auto.isGenerating, "the timer path enters generating")
        let manual = await auto.generate(sessionId: session, explicit: true)
        XCTAssertNil(manual, "Suggest now shares the busy guard with the timer path")
        await waitUntilIdle(auto)

        XCTAssertFalse(auto.isGenerating, "the pass released its own busy state")
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(auto.cards.map(\.text), ["Ask who signs off", "Say the renewal is in March"])
        XCTAssertEqual(auto.pass.watermarkMs, 4000, "an accepted pass moves the watermark")
        XCTAssertEqual(auto.rail.nowItems.map(\.text), ["Ask who signs off"], "the rail shows one card per spacing")
        XCTAssertEqual(auto.rail.waitingCount, 1)
        auto.stop()
    }

    func testSuggestNowShowsItsFirstCardAtOnceInsteadOfWaitingOutTheSpacing() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        let first = [entry("remote", "When is the renewal?", 1000), entry("remote", "Who approves it?", 4000)]
        startRecording(first)
        defer { stopRecording() }
        let calls = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await calls.bump()
            let text = await calls.count == 1 ? Self.twoCards
                : #"{"cards":[{"kind":"ask","text":"Ask what the pilot costs","why":"Price came up."}]}"#
            return LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        _ = await auto.generate(sessionId: session)
        XCTAssertEqual(auto.rail.nowItems.map(\.text), ["Ask who signs off"])

        rig.clock = rig.clock.addingTimeInterval(10)
        seed(first + [entry("remote", "And what does the pilot cost?", 8000)])
        _ = await auto.generate(sessionId: session, explicit: true)
        XCTAssertEqual(auto.rail.nowItems.map(\.text), ["Ask what the pilot costs", "Ask who signs off"],
                       "an explicit request skips the 60 s spacing for its first card")
        XCTAssertEqual(auto.rail.requestedID, auto.rail.nowItems.first?.id)
        XCTAssertEqual(auto.rail.waitingCount(in: .now), 1, "the first pass's second card still waits")
        auto.stop()
    }

    func testTheSchedulerTickWaitsForTheFloorAndSuggestNowDoesNot() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        var lines = [entry("remote", "When is the renewal?", 1000)]
        startRecording(lines)
        defer { stopRecording() }
        let calls = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await calls.bump()
            return LLMClient.CollectedResponse(text: #"{"cards":[]}"#, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request, callType: .research)
        let start = rig.clock
        let floor = AutoPassState.floor(for: .research) ?? 60
        let first = await auto.generate(sessionId: session)
        XCTAssertNotNil(first)

        for (second, line) in [(10.0, 2000), (floor - 1, 3000)] {
            rig.clock = start.addingTimeInterval(second)
            lines.append(entry("remote", "More talk \(line).", line))
            seed(lines)
            let tick = await auto.generate(sessionId: session)
            XCTAssertNil(tick, "a tick \(second) s after the last pass waits for the floor")
        }
        var count = await calls.count
        XCTAssertEqual(count, 1, "no paid pass inside the floor")

        let manual = await auto.generate(sessionId: session, explicit: true)
        XCTAssertNotNil(manual, "Suggest now skips the floor")
        rig.clock = start.addingTimeInterval(2 * floor)
        lines.append(entry("remote", "Later talk.", 9000))
        seed(lines)
        let late = await auto.generate(sessionId: session)
        XCTAssertNotNil(late, "a tick a floor after the last pass runs")
        count = await calls.count
        XCTAssertEqual(count, 3)
        auto.stop()
    }

    func testOnlyCardsTheUserSawAreSentAsAlreadySurfaced() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal?", 1000), entry("remote", "Who approves it?", 4000)])
        defer { stopRecording() }
        let request = LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: Self.twoCards, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        _ = await auto.generate(sessionId: session)
        XCTAssertEqual(auto.rail.nowItems.map(\.text), ["Ask who signs off"])
        XCTAssertEqual(auto.rail.waitingCount, 1, "the second card was paid for but not shown")
        XCTAssertEqual(auto.surfacedCards.map(\.text), ["Ask who signs off"])

        seed([entry("remote", "When is the renewal?", 1000), entry("remote", "Who approves it?", 4000),
              entry("remote", "And the pilot?", 6000)])
        let pass = try await unwrapPass(auto, from: auto.pass.watermarkMs)
        XCTAssertTrue(pass.prompt.contains("Ask who signs off"), "a shown card is not repeated")
        XCTAssertFalse(pass.prompt.contains("Say the renewal is in March"),
                       "a card the pacer never showed is not marked as surfaced")

        // The waiting card fades unseen. A later pass may bring it back.
        rig.clock = rig.clock.addingTimeInterval(LiveRailPacer.standard.fadeAfter + 1)
        _ = await auto.generate(sessionId: session)
        XCTAssertTrue(auto.rail.items.contains { $0.text == "Say the renewal is in March" && $0.state != .expired },
                      "the unseen card came back")
        XCTAssertEqual(auto.rail.items.filter { $0.text == "Ask who signs off" }.count, 1, "the seen card did not")
        auto.stop()
    }

    func testFailedPassKeepsTheWatermarkAndReleasesBusy() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal?", 1000)])
        defer { stopRecording() }
        let request = LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: "  ", finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        let result = await auto.generate(sessionId: session)
        XCTAssertNil(result)
        XCTAssertFalse(auto.isGenerating)
        XCTAssertEqual(auto.pass.watermarkMs, 0, "a failed pass reads the same window again")
        XCTAssertEqual(auto.pass.phase, .idle)
        XCTAssertTrue(auto.cards.isEmpty)
        XCTAssertTrue(auto.rail.items.isEmpty, "a failed pass offers the rail nothing")
    }

    func testTurningAutoOffMidDebounceDropsThePendingPass() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal?", 1000)])
        defer { stopRecording() }
        let calls = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await calls.bump()
            return LLMClient.CollectedResponse(text: Self.twoCards, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        auto.noteActivity()
        XCTAssertNotEqual(auto.pass.phase, .idle)

        rig.defaults.set(false, forKey: AutoAssistSettings.enabledKey)
        rig.clock = rig.clock.addingTimeInterval(AutoPassState.quietWindow + 1)
        auto.timerFired()
        XCTAssertEqual(auto.pass.phase, .idle, "cancelPending drops the waiting pass")
        XCTAssertFalse(auto.isGenerating)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 0, "no paid pass after Auto was turned off")
        auto.noteActivity()
        XCTAssertEqual(auto.pass.phase, .idle, "new talk does not arm Auto while it is off")
    }

    func testStopDropsARunningTimerPassAndItsCards() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal?", 1000)])
        defer { stopRecording() }
        let gate = AutoResponseGate()
        let request = LLMRequest(collectStream: { _, _, _, _ in await gate.collect() },
                                 priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        auto.noteActivity()
        rig.clock = rig.clock.addingTimeInterval(AutoPassState.quietWindow + 1)
        auto.timerFired()
        XCTAssertTrue(auto.isGenerating)
        await gate.waitForCall()

        auto.stop()
        XCTAssertEqual(auto.pass.phase, .idle, "stop moves the pass machine to idle")
        XCTAssertEqual(auto.pass.generation, 1, "stop bumps the generation")
        await gate.finish(Self.twoCards)
        // Give the cancelled pass time to see its reply and report back.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(auto.cards.isEmpty, "a reply that lands after stop adds no cards")
        XCTAssertTrue(auto.rail.items.isEmpty, "and offers nothing to the rail")
        XCTAssertEqual(auto.pass.watermarkMs, 0)
        XCTAssertFalse(auto.isGenerating)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func bump() {
        count += 1
    }
}

/// Holds one provider reply until the test releases it; no sleeps or network.
private actor AutoResponseGate {
    private var call: CheckedContinuation<LLMClient.CollectedResponse, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func collect() async -> LLMClient.CollectedResponse {
        await withCheckedContinuation { continuation in
            call = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForCall() async {
        guard call == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ text: String) {
        call?.resume(returning: LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0))
        call = nil
    }
}
