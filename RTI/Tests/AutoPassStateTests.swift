import RTICore
import XCTest

final class AutoPassStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let clientFloor: TimeInterval = 25

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - Transitions

    private struct Step {
        let event: AutoPassState.Event
        let second: TimeInterval
        let effect: AutoPassState.Effect
        let phase: AutoPassState.Phase
    }

    private func run(_ name: String, _ steps: [Step]) -> AutoPassState {
        var state = AutoPassState()
        for (index, step) in steps.enumerated() {
            let effect = state.reduce(step.event, now: at(step.second), floor: clientFloor)
            XCTAssertEqual(effect, step.effect, "\(name), step \(index): \(step.event)")
            XCTAssertEqual(state.phase, step.phase, "\(name), step \(index): \(step.event)")
        }
        return state
    }

    func testTransitionTable() {
        let quiet = AutoPassState.quietWindow
        let cases: [(String, [Step])] = [
            ("first final debounces, then the pass starts", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .timerFired, second: quiet, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 900), second: 10, effect: .none, phase: .idle),
            ]),
            ("more talk re-arms the debounce", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .activity, second: 3, effect: .arm(at: at(3 + quiet)), phase: .debouncing(until: at(3 + quiet))),
            ]),
            ("an early timer waits for the debounce", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .timerFired, second: 2, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
            ]),
            ("settled talk inside the floor waits for it", [
                Step(event: .passRequested, second: 0, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 100), second: 1, effect: .none, phase: .idle),
                Step(event: .activity, second: 2, effect: .arm(at: at(2 + quiet)), phase: .debouncing(until: at(2 + quiet))),
                Step(event: .timerFired, second: 2 + quiet, effect: .arm(at: at(25)), phase: .waitingFloor(until: at(25))),
                Step(event: .activity, second: 12, effect: .none, phase: .waitingFloor(until: at(25))),
                Step(event: .timerFired, second: 25, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
            ]),
            ("the tick waits for the floor; Suggest now does not", [
                Step(event: .tick, second: 0, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 100), second: 1, effect: .none, phase: .idle),
                Step(event: .tick, second: 10, effect: .none, phase: .idle),
                Step(event: .passRequested, second: 11, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 200), second: 12, effect: .none, phase: .idle),
                Step(event: .tick, second: 11 + 24, effect: .none, phase: .idle),
                Step(event: .tick, second: 11 + 25, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .tick, second: 40, effect: .none, phase: .generating(generation: 0)),
            ]),
            ("a tick inside the floor leaves a waiting debounce armed", [
                Step(event: .passRequested, second: 0, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 100), second: 1, effect: .none, phase: .idle),
                Step(event: .activity, second: 2, effect: .arm(at: at(2 + quiet)), phase: .debouncing(until: at(2 + quiet))),
                Step(event: .tick, second: 3, effect: .none, phase: .debouncing(until: at(2 + quiet))),
            ]),
            ("tick and Suggest now share the busy guard", [
                Step(event: .passRequested, second: 0, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .passRequested, second: 1, effect: .none, phase: .generating(generation: 0)),
                Step(event: .timerFired, second: 2, effect: .none, phase: .generating(generation: 0)),
            ]),
            ("Suggest now overtakes a waiting debounce", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .passRequested, second: 1, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
            ]),
            ("talk during a pass debounces again after it", [
                Step(event: .passRequested, second: 0, effect: .startPass(generation: 0), phase: .generating(generation: 0)),
                Step(event: .activity, second: 1, effect: .none, phase: .generating(generation: 0)),
                Step(event: .passFinished(generation: 0, endMs: 50), second: 4, effect: .arm(at: at(4 + quiet)),
                     phase: .debouncing(until: at(4 + quiet))),
            ]),
            ("turning Auto off drops a waiting pass", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .cancelPending, second: 1, effect: .disarm, phase: .idle),
                Step(event: .cancelPending, second: 2, effect: .none, phase: .idle),
            ]),
            ("reset from any phase goes idle", [
                Step(event: .activity, second: 0, effect: .arm(at: at(quiet)), phase: .debouncing(until: at(quiet))),
                Step(event: .reset, second: 1, effect: .disarm, phase: .idle),
                Step(event: .passRequested, second: 2, effect: .startPass(generation: 1), phase: .generating(generation: 1)),
                Step(event: .reset, second: 3, effect: .disarm, phase: .idle),
            ]),
        ]
        for (name, steps) in cases {
            _ = run(name, steps)
        }
    }

    func testFloorsMatchTheRailSpacing() {
        let spacing = LiveRailPacer.standard.spacing
        XCTAssertEqual(AutoPassState.floor(for: .client), spacing, "a client pass is not paid for faster than the rail shows")
        XCTAssertEqual(AutoPassState.floor(for: .research), 150, "a moderator uses at most one card every 2 to 3 minutes")
        XCTAssertEqual(AutoPassState.floor(for: .research, format: .interview), 150)
        XCTAssertEqual(AutoPassState.floor(for: .research, format: .group), 180, "three or more voices: every FGD")
        XCTAssertEqual(AutoPassState.floor(for: .client, format: .group), spacing, "the format is research only")
        XCTAssertNil(AutoPassState.floor(for: .internal))
        XCTAssertNil(AutoPassState.floor(for: .personal))

        var state = AutoPassState()
        state.reduce(.passRequested, now: at(0), floor: 60)
        state.reduce(.passFinished(generation: 0, endMs: 10), now: at(1), floor: 60)
        state.reduce(.activity, now: at(30), floor: 60)
        let effect = state.reduce(.timerFired, now: at(30 + AutoPassState.quietWindow), floor: 60)
        XCTAssertEqual(effect, .arm(at: at(60)))
    }

    // MARK: - Watermark and generations

    func testAcceptedPassAdvancesWatermarkAndFailureKeepsIt() {
        var state = AutoPassState()
        state.reduce(.passRequested, now: at(0), floor: clientFloor)
        state.reduce(.passFinished(generation: 0, endMs: 4000), now: at(1), floor: clientFloor)
        XCTAssertEqual(state.watermarkMs, 4000)

        state.reduce(.passRequested, now: at(30), floor: clientFloor)
        state.reduce(.passFinished(generation: 0, endMs: nil), now: at(31), floor: clientFloor)
        XCTAssertEqual(state.watermarkMs, 4000, "a failed pass reads its window again")
        XCTAssertEqual(state.phase, .idle)
    }

    func testASkippedPassGivesBackItsFloorAndKeepsTheWatermark() {
        let floor: TimeInterval = 150
        var state = AutoPassState()
        state.reduce(.passRequested, now: at(0), floor: floor)
        state.reduce(.passFinished(generation: 0, endMs: 4000), now: at(5), floor: floor)

        // The floor passes; the next pass finds a thin window and sends nothing.
        XCTAssertEqual(state.reduce(.tick, now: at(150), floor: floor), .startPass(generation: 0))
        XCTAssertEqual(state.reduce(.passSkipped(generation: 0), now: at(150), floor: floor), .none)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.watermarkMs, 4000)
        XCTAssertEqual(state.lastPassAt, at(0), "the skipped pass took no floor")

        // Respondent talk settles a few seconds later: checked at once, no 150 s wait.
        let quiet = AutoPassState.quietWindow
        XCTAssertEqual(state.reduce(.activity, now: at(155), floor: floor), .arm(at: at(155 + quiet)))
        XCTAssertEqual(state.reduce(.timerFired, now: at(155 + quiet), floor: floor), .startPass(generation: 0))
        state.reduce(.passFinished(generation: 0, endMs: 9000), now: at(170), floor: floor)
        XCTAssertEqual(state.lastPassAt, at(155 + quiet), "a sent pass takes the floor")
        XCTAssertEqual(state.reduce(.tick, now: at(200), floor: floor), .none)

        // Talk during a skipped pass debounces again; a stale skip changes nothing.
        state.reduce(.passRequested, now: at(400), floor: floor)
        state.reduce(.activity, now: at(401), floor: floor)
        XCTAssertEqual(state.reduce(.passSkipped(generation: 0), now: at(402), floor: floor), .arm(at: at(402 + quiet)))
        state.reduce(.stop, now: at(403), floor: floor)
        XCTAssertEqual(state.reduce(.passSkipped(generation: 0), now: at(404), floor: floor), .none)
        XCTAssertEqual(state.phase, .idle)
    }

    func testStaleGenerationResultIsDropped() {
        var state = AutoPassState()
        state.reduce(.passRequested, now: at(0), floor: clientFloor)
        XCTAssertTrue(state.owns(generation: 0))
        state.reduce(.reset, now: at(1), floor: clientFloor)
        XCTAssertEqual(state.generation, 1)
        state.reduce(.passRequested, now: at(2), floor: clientFloor)

        XCTAssertFalse(state.owns(generation: 0))
        let effect = state.reduce(.passFinished(generation: 0, endMs: 9999), now: at(3), floor: clientFloor)
        XCTAssertEqual(effect, .none)
        XCTAssertEqual(state.watermarkMs, 0, "the old pass must not move the new session's watermark")
        XCTAssertEqual(state.phase, .generating(generation: 1), "the old pass must not release the new one")

        state.reduce(.passFinished(generation: 1, endMs: 200), now: at(4), floor: clientFloor)
        XCTAssertEqual(state.watermarkMs, 200)
        XCTAssertFalse(state.isGenerating)
    }

    func testStaleResultAfterResetLeavesIdleState() {
        var state = AutoPassState()
        state.reduce(.passRequested, now: at(0), floor: clientFloor)
        state.reduce(.reset, now: at(1), floor: clientFloor)
        state.reduce(.passFinished(generation: 0, endMs: 700), now: at(2), floor: clientFloor)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.watermarkMs, 0)
        XCTAssertNil(state.lastPassAt)
    }

    func testStopFromEveryPhaseGoesIdleAndDropsTheRunningPass() {
        var debouncing = AutoPassState()
        debouncing.reduce(.activity, now: at(0), floor: clientFloor)
        XCTAssertEqual(debouncing.reduce(.stop, now: at(1), floor: clientFloor), .disarm)
        XCTAssertEqual(debouncing.phase, .idle)
        XCTAssertEqual(debouncing.reduce(.timerFired, now: at(30), floor: clientFloor), .none,
                       "a timer that fires after stop starts nothing")

        var waiting = AutoPassState()
        waiting.reduce(.passRequested, now: at(0), floor: clientFloor)
        waiting.reduce(.passFinished(generation: 0, endMs: 100), now: at(1), floor: clientFloor)
        waiting.reduce(.activity, now: at(2), floor: clientFloor)
        waiting.reduce(.timerFired, now: at(9), floor: clientFloor)
        XCTAssertEqual(waiting.phase, .waitingFloor(until: at(25)))
        XCTAssertEqual(waiting.reduce(.stop, now: at(10), floor: clientFloor), .disarm)
        XCTAssertEqual(waiting.phase, .idle)

        var running = AutoPassState()
        running.reduce(.passRequested, now: at(0), floor: clientFloor)
        running.reduce(.passFinished(generation: 0, endMs: 400), now: at(1), floor: clientFloor)
        running.reduce(.passRequested, now: at(30), floor: clientFloor)
        running.reduce(.activity, now: at(31), floor: clientFloor)
        XCTAssertEqual(running.reduce(.stop, now: at(32), floor: clientFloor), .disarm)
        XCTAssertEqual(running.phase, .idle)
        XCTAssertEqual(running.generation, 1)
        XCTAssertFalse(running.owns(generation: 0), "the pass started before stop can no longer apply its cards")
        XCTAssertEqual(running.reduce(.passFinished(generation: 0, endMs: 900), now: at(33), floor: clientFloor), .none)
        XCTAssertEqual(running.watermarkMs, 400, "stop keeps the watermark; the late reply does not move it")
        XCTAssertFalse(running.activityDuringPass)
    }

    // MARK: - isActive(for:)

    func testIsActiveTruthTable() {
        let expected: [(CallType, Bool?, Bool)] = [
            (.client, nil, true), (.client, true, true), (.client, false, false),
            (.research, nil, true), (.research, true, true), (.research, false, false),
            (.internal, nil, false), (.internal, true, false), (.internal, false, false),
            (.personal, nil, false), (.personal, true, false), (.personal, false, false),
        ]
        XCTAssertEqual(expected.count, CallType.allCases.count * 3)
        for (callType, stored, active) in expected {
            XCTAssertEqual(AutoAssistSettings.isActive(for: callType, stored: stored), active,
                           "\(callType) stored \(String(describing: stored))")
        }
    }

    /// The tick cannot add passes on top of the debounce: over an hour of
    /// steady talk, with the debounce and a 120 s tick both firing, passes
    /// never start closer together than the floor.
    func testDebounceAndTickTogetherNeverBeatTheFloor() {
        for callType in [CallType.client, .research] {
            let floor = AutoPassState.floor(for: callType) ?? 0
            var state = AutoPassState()
            var starts: [TimeInterval] = []
            var armedAt: TimeInterval?
            for second in stride(from: 0.0, through: 3600, by: 1) {
                var effects: [AutoPassState.Effect] = []
                if second.truncatingRemainder(dividingBy: 5) == 0 {
                    effects.append(state.reduce(.activity, now: at(second), floor: floor))
                }
                if let due = armedAt, second >= due {
                    armedAt = nil
                    effects.append(state.reduce(.timerFired, now: at(second), floor: floor))
                }
                if second.truncatingRemainder(dividingBy: 120) == 0 {
                    effects.append(state.reduce(.tick, now: at(second), floor: floor))
                }
                for effect in effects {
                    switch effect {
                    case let .arm(date): armedAt = date.timeIntervalSince(t0)
                    case .disarm: armedAt = nil
                    case .startPass:
                        armedAt = nil
                        starts.append(second)
                    case .none: break
                    }
                }
                // Each pass takes two seconds.
                if state.isGenerating, let last = starts.last, second >= last + 2 {
                    let finished = state.reduce(.passFinished(generation: state.generation, endMs: Int(second) * 1000),
                                                now: at(second), floor: floor)
                    if case let .arm(date) = finished {
                        armedAt = date.timeIntervalSince(t0)
                    }
                }
            }
            let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
            XCTAssertFalse(starts.isEmpty, "\(callType)")
            XCTAssertGreaterThanOrEqual(gaps.min() ?? floor, floor, "\(callType): passes at \(starts.prefix(8))")
            XCTAssertLessThanOrEqual(starts.count, Int(3600 / floor) + 1, "\(callType)")
        }
    }

    // MARK: - Opt-in era migration

    func testMigrationDropsAnOptInEraFalseOnceAndKeepsALaterChoice() throws {
        let suite = "AutoPassStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AutoAssistSettings.enabledKey)
        XCTAssertFalse(AutoAssistSettings.isActive(for: .client, defaults: defaults), "before: the leftover false wins")

        AutoAssistSettings.migrateOptInEraValue(in: defaults)
        XCTAssertNil(defaults.object(forKey: AutoAssistSettings.enabledKey))
        XCTAssertTrue(AutoAssistSettings.isActive(for: .client, defaults: defaults), "after: the default-on decision reaches the install")
        XCTAssertTrue(AutoAssistSettings.isActive(for: .research, defaults: defaults))

        defaults.set(false, forKey: AutoAssistSettings.enabledKey)
        AutoAssistSettings.migrateOptInEraValue(in: defaults)
        XCTAssertEqual(defaults.object(forKey: AutoAssistSettings.enabledKey) as? Bool, false,
                       "a false the user sets after the migration stays")
    }

    func testMigrationKeepsAStoredTrueAndMarksAnUnsetInstall() throws {
        let suite = "AutoPassStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AutoAssistSettings.enabledKey)
        AutoAssistSettings.migrateOptInEraValue(in: defaults)
        XCTAssertEqual(defaults.object(forKey: AutoAssistSettings.enabledKey) as? Bool, true)

        let fresh = try XCTUnwrap(UserDefaults(suiteName: suite + ".fresh"))
        defer { fresh.removePersistentDomain(forName: suite + ".fresh") }
        AutoAssistSettings.migrateOptInEraValue(in: fresh)
        XCTAssertTrue(fresh.bool(forKey: AutoAssistSettings.defaultOnMigrationKey), "the flag is set on every first run")
        fresh.set(false, forKey: AutoAssistSettings.enabledKey)
        AutoAssistSettings.migrateOptInEraValue(in: fresh)
        XCTAssertEqual(fresh.object(forKey: AutoAssistSettings.enabledKey) as? Bool, false)
    }

    func testIsActiveReadsUnsetAsUnset() throws {
        let suite = "AutoPassStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AutoAssistSettings.isActive(for: .client, defaults: defaults))
        XCTAssertFalse(AutoAssistSettings.isActive(for: .internal, defaults: defaults))
        defaults.set(false, forKey: AutoAssistSettings.enabledKey)
        XCTAssertFalse(AutoAssistSettings.isActive(for: .client, defaults: defaults))
        defaults.set(true, forKey: AutoAssistSettings.enabledKey)
        XCTAssertTrue(AutoAssistSettings.isActive(for: .research, defaults: defaults))
        XCTAssertFalse(AutoAssistSettings.isActive(for: .personal, defaults: defaults),
                       "a stored true cannot show Auto on a call type where it never runs")
    }
}
