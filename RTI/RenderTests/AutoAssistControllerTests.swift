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

    /// A guide whose S1 closed with nothing filed, past the late-start
    /// window, and a guide pass that just succeeded.
    private func activeGuide(passSucceeded: Bool = true) throws -> GuideSessionController {
        let guide = try startedGuide()
        guide.select("S2Q1", at: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(400))
        XCTAssertFalse(guide.gaps.isEmpty)
        if passSucceeded { guide.notePassSucceededForTest(at: Date()) }
        return guide
    }

    private func startedGuide() throws -> GuideSessionController {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let document = try GuideDocument.parse(Data(contentsOf: url))
        let guide = GuideSessionController()
        guide.start(sessionID: "auto-guide-fixture", guide: document, guideURL: url, group: nil, roster: [],
                    rosterURL: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
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
        XCTAssertFalse(idle.prompt.contains(AutoAssistPrompt.guidePositionUncertainLine), "no guide, no guide line")
    }

    func testGuidePositionAndGapsGoInOnlyWhileAGuidePassIsFresh() async throws {
        seed([entry("remote", "我一般随便买。", 1000)])
        // Following live, no pass yet: the position is uncertain and gaps stay out.
        let guide = try startedGuide()
        let unplaced = try await unwrapPass(controller(.research, guide: guide), from: 0)
        XCTAssertTrue(unplaced.prompt.contains(AutoAssistPrompt.guidePositionUncertainLine))
        XCTAssertFalse(unplaced.prompt.contains("Current guide question"))

        guide.notePassSucceededForTest(at: Date(), position: "S1Q2")
        let placed = try await unwrapPass(controller(.research, guide: guide), from: 0)
        XCTAssertTrue(placed.prompt.contains("Current guide question:\nS1Q2 / How would you carry the cup?"))
        XCTAssertFalse(placed.prompt.contains(AutoAssistPrompt.guidePositionUncertainLine))

        guide.notePassSucceededForTest(at: Date().addingTimeInterval(-300), position: "S1Q2")
        let stale = try await unwrapPass(controller(.research, guide: guide), from: 0)
        XCTAssertTrue(stale.prompt.contains(AutoAssistPrompt.guidePositionUncertainLine), "a position over four minutes old is stale")

        let gapsStale = try await unwrapPass(controller(.research, guide: activeGuide(passSucceeded: false)), from: 0)
        XCTAssertFalse(gapsStale.prompt.contains("Guide gaps"), "gaps need a guide pass in the last four minutes")
        XCTAssertTrue(gapsStale.prompt.contains("Current guide question:\nS2Q1"), "the user's own pick is always fresh")
    }

    /// A line timed one character every 200 ms, as provider tokens.
    private func timed(_ speaker: String, _ text: String, _ start: Int) -> LiveEntry {
        let tokens = text.enumerated().map { offset, character in
            LiveEntry.TimedToken(text: String(character), startMs: start + offset * 200, endMs: start + offset * 200 + 150)
        }
        return LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1, translationStatus: "none",
                         language: "zh", sourceLanguage: nil, textOrigin: .providerTokens, streamID: UUID(), tokens: tokens)
    }

    func testResearchLinesCarryTheRoleHintAndLoseMicEchoes() async throws {
        // An in-room group played on a speaker: the mic hears each room line
        // at the same time, so the room is on both legs and its echoes go.
        let room = ["你平时早上喝什么？我一般喝燕麦奶。", "我觉得这个包装很好看，颜色也很清爽。", "价格的话我觉得有点贵，不太划算。"]
        seed(room.enumerated().flatMap { index, line in
            [timed("remote", line, 1000 + index * 15000),
             timed("self", line.filter { !"，。？".contains($0) }, 1200 + index * 15000)]
        })
        let research = try await unwrapPass(controller(.research), from: 0)
        XCTAssertTrue(research.prompt.contains("Them, moderator] 你平时早上喝什么？"), research.prompt)
        XCTAssertTrue(research.prompt.contains("Them, respondent] 我一般喝燕麦奶。"))
        XCTAssertFalse(research.prompt.contains("Me]"), "the mic echo of the room is dropped")

        // One overlapping repeat on an otherwise remote call is not a room on both legs.
        seed([timed("remote", room[0], 1000), timed("self", "你平时早上喝什么我一般喝燕麦奶", 1200)])
        let remote = try await unwrapPass(controller(.research), from: 0)
        XCTAssertTrue(remote.prompt.contains("Me] 你平时早上喝什么我一般喝燕麦奶"), "no echo is dropped without the room gate")

        seed([entry("remote", "我一般喝燕麦奶。", 1000), entry("self", "Note the oat point for later.", 1200)])
        let own = try await unwrapPass(controller(.research), from: 0)
        XCTAssertTrue(own.prompt.contains("Me] Note the oat point for later."), "the user's own words stay")
        let client = try await unwrapPass(controller(.client), from: 0)
        XCTAssertFalse(client.prompt.contains("moderator]"), "client calls get no role hint")
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
        // Research passes need enough new respondent talk, so every line is long.
        var lines = [entry("remote", Self.longAnswer, 1000)]
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
            lines.append(entry("remote", "\(Self.longAnswer) \(line)", line))
            seed(lines)
            let tick = await auto.generate(sessionId: session)
            XCTAssertNil(tick, "a tick \(second) s after the last pass waits for the floor")
        }
        var count = await calls.count
        XCTAssertEqual(count, 1, "no paid pass inside the floor")

        let manual = await auto.generate(sessionId: session, explicit: true)
        XCTAssertNotNil(manual, "Suggest now skips the floor")
        rig.clock = start.addingTimeInterval(2 * floor)
        lines.append(entry("remote", Self.longAnswer + "后来。", 9000))
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

// MARK: - Research rules (P4 to P7, invented text)

@MainActor
extension AutoAssistControllerTests {
    /// About 170 respondent characters: one pass's worth in a group.
    static let longAnswer = String(repeating: "我平时早上一般喝燕麦奶，因为觉得比较健康，而且味道也不错，", count: 6)

    private func reply(_ text: String) -> LLMRequest {
        LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
    }

    func testResearchSkipsAPassOnThinRespondentInputAndKeepsTheWatermark() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        // Moderator questions and a short answer: under 150 respondent characters.
        startRecording([entry("remote", "你平时早上喝什么？", 1000), entry("remote", "燕麦奶。", 3000),
                        entry("self", "Note to self.", 4000)])
        defer { stopRecording() }
        let calls = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await calls.bump()
            return LLMClient.CollectedResponse(text: #"{"cards":[]}"#, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request, callType: .research)
        let thin = await auto.generate(sessionId: session)
        XCTAssertNil(thin)
        let none = await calls.count
        XCTAssertEqual(none, 0, "no paid pass on thin respondent input")
        XCTAssertEqual(auto.pass.watermarkMs, 0, "the thin window is read again next time")
        XCTAssertNil(auto.pass.lastPassAt, "the skipped pass took no floor")
        XCTAssertFalse(auto.isGenerating)

        // A long answer a few seconds later is read at once, not after the floor.
        seed([entry("remote", "你平时早上喝什么？", 1000), entry("remote", Self.longAnswer, 3000)])
        rig.clock = rig.clock.addingTimeInterval(5)
        let full = await auto.generate(sessionId: session)
        XCTAssertEqual(full, 3000)
        let one = await calls.count
        XCTAssertEqual(one, 1)
    }

    func testAMandarinResearchPassShowsOneCardWithItsMandarinLine() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", Self.longAnswer, 1000)])
        defer { stopRecording() }
        let json = #"""
        {"cards":[
          {"kind":"ASK","text_en":"Ask what healthy means here","text_zh":null,"why":"Vague word."},
          {"kind":"RECALL","text_en":"Round 1 said the same","why":"Echo.","source":null},
          {"kind":"ASK","text_en":"Ask the room who sees it differently","text_zh":"有没有人不一样的看法？","why":"One view so far."},
          {"kind":"ASK","text_en":"Ask why taste matters","text_zh":"为什么味道对你重要？","why":"Laddering."}
        ]}
        """#
        let auto = liveController(rig, request: reply(json), callType: .research)
        _ = await auto.generate(sessionId: session)
        XCTAssertEqual(auto.cards.map(\.text), ["Ask the room who sees it differently"],
                       "no Mandarin line, no source, and a second card in one research pass are all dropped")
        XCTAssertEqual(auto.cards.first?.textZH, "有没有人不一样的看法？")
        XCTAssertNotNil(auto.cards.first?.pinyin)

        auto.stop()
    }

    func testANearRepeatWithinFifteenMinutesIsDropped() async {
        let rig = Rig()
        defer { rig.cleanUp() }
        startRecording([entry("remote", "When is the renewal? We still need the owner and the budget line.", 1000)])
        defer { stopRecording() }
        let counter = CallCounter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            await counter.bump()
            let text = await counter.count == 1
                ? #"{"cards":[{"kind":"ask","text_en":"Ask who signs off on the budget","why":"No owner."}]}"#
                : #"{"cards":[{"kind":"ask","text_en":"Ask who signs off the budget","why":"Still no owner."}]}"#
            return LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let auto = liveController(rig, request: request)
        _ = await auto.generate(sessionId: session)
        XCTAssertEqual(auto.rail.nowItems.map(\.text), ["Ask who signs off on the budget"])
        rig.clock = rig.clock.addingTimeInterval(120)
        seed([entry("remote", "When is the renewal? We still need the owner and the budget line.", 1000),
              entry("remote", "And the pilot budget?", 6000)])
        _ = await auto.generate(sessionId: session)
        XCTAssertEqual(auto.cards.count, 1, "a paraphrase of a card shown 2 minutes ago is a repeat")
        auto.stop()
    }

    func testResearchPromptCarriesBudgetsAndTheSilentLegSignal() async throws {
        // Them spoke at 0:01, then only the mic for 4 minutes.
        seed([entry("remote", Self.longAnswer, 1000), entry("self", "Let me check the audio.", 241_000)])
        let guide = try activeGuide()
        let pass = try await unwrapPass(controller(.research, guide: guide), from: 0)
        XCTAssertTrue(pass.prompt.contains("Guide section budgets:\n- S1 SECTION 1: Cups (6 min): 6 min"), pass.prompt)
        XCTAssertTrue(pass.prompt.contains("No Them speech for 4 min (since 0:01)"))
        XCTAssertTrue(pass.mandarin, "the window is mostly Chinese")
        XCTAssertTrue(pass.prompt.contains(AutoAssistPrompt.mandarinLine))

        let client = try await unwrapPass(controller(.client, guide: guide), from: 0)
        XCTAssertFalse(client.prompt.contains("Guide section budgets"))
        XCTAssertFalse(client.prompt.contains("Signals"))
    }

    func testTheResearchFloorFollowsTheRoster() throws {
        let guide = try startedGuide()
        XCTAssertEqual(controller(.research, guide: guide).researchFormat, .unknown, "a mock title and no roster")
        let group = GuideSessionController()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let document = try GuideDocument.parse(Data(contentsOf: url))
        group.start(sessionID: "auto-group", guide: document, guideURL: url, group: nil,
                    roster: (1 ... 6).map { GuideSeat(seat: $0, label: "R\($0)", segment: "A") }, rosterURL: nil)
        XCTAssertEqual(controller(.research, guide: group).researchFormat, .group)
    }

    func testOlderSurfacedCardsBecomeShortTopics() {
        XCTAssertEqual(AutoAssistController.topic("Ask who signs off on the budget and by when"), "Ask who signs off on the")
        XCTAssertEqual(AutoAssistController.topic("有没有人不一样的看法？"), "有没有人不一样的看法？")
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
