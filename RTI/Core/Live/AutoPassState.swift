import Foundation

/// When the next Auto pass may run, as one pure value.
///
/// The phases are `idle -> debouncing(until) -> waitingFloor(until) ->
/// generating(generation) -> idle`. A committed final starts the debounce, so a
/// pass acts on a finished thought. The floor bounds cost: the debounce and
/// the scheduler tick never start a pass sooner than the call type's floor
/// after the one before it, so automatic passes run at most once per floor.
/// Only "Suggest now", which the user asks for, skips the floor. The tick and
/// "Suggest now" enter `generating` through the same busy guard.
///
/// A pass that fails keeps the watermark, so its window is read again. A
/// pass skipped before any request (a thin research window) also gives
/// back its floor: the next settled talk checks again at once. A stop or
/// reset bumps the generation, so a result from an older pass is dropped.
/// The value holds no timer: each event returns the one effect the owner
/// must apply.
public struct AutoPassState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Talk is still landing; fire when it has been quiet until then.
        case debouncing(until: Date)
        /// Talk has settled, but the floor since the last pass has not passed.
        case waitingFloor(until: Date)
        case generating(generation: Int)
    }

    public enum Event: Equatable, Sendable {
        /// A committed final landed while Auto is active and recording.
        case activity
        /// The armed timer fired.
        case timerFired
        /// The scheduler tick. It starts a pass only once the floor since the
        /// last pass has passed; otherwise it changes nothing.
        case tick
        /// "Suggest now": the user asked, so it skips the floor.
        case passRequested
        /// A pass ended. `endMs` is the watermark of an accepted response;
        /// nil means the pass failed or found nothing new.
        case passFinished(generation: Int, endMs: Int?)
        /// An admitted pass sent nothing (too little new respondent talk).
        /// It keeps the watermark and gives back the floor it took, so the
        /// next settled talk is checked again without a new floor wait.
        case passSkipped(generation: Int)
        /// Auto was turned off or the recording ended: drop a waiting pass,
        /// keep the watermark.
        case cancelPending
        /// The recording stopped: drop any waiting or running pass. It bumps
        /// the generation so a pass still awaiting its reply is dropped, and
        /// keeps the watermark.
        case stop
        /// A session reset.
        case reset
    }

    public enum Effect: Equatable, Sendable {
        /// Leave any armed timer as it is.
        case none
        /// Cancel any armed timer.
        case disarm
        /// Cancel any armed timer and arm one for this time.
        case arm(at: Date)
        /// Cancel any armed timer and run a pass for this generation.
        case startPass(generation: Int)
    }

    /// Quiet time after the last final before a pass fires.
    public static let quietWindow: TimeInterval = 7

    /// The minimum time between passes, or nil when the call type has no Auto.
    /// A client call matches the rail's spacing (`LiveRailPacer.spacing`,
    /// 60 s), so a paid pass is not made faster than the rail can show its
    /// first card. A research call runs every 150 s, and every 180 s in a
    /// group (three or more voices): a moderator can use at most one card
    /// every 2 to 3 minutes.
    public static func floor(for callType: CallType, format: ResearchFormat = .unknown) -> TimeInterval? {
        switch callType {
        case .client: 60
        case .research: format == .group ? 180 : 150
        case .internal, .personal: nil
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var generation = 0
    /// Ms of the last transcript an accepted pass covered.
    public private(set) var watermarkMs = 0
    public private(set) var lastPassAt: Date?
    /// `lastPassAt` before the running pass started, for `passSkipped`.
    private var lastPassBeforeRun: Date?
    /// A final landed while a pass ran; debounce again when it ends.
    public private(set) var activityDuringPass = false

    public init() {}

    public var isGenerating: Bool {
        if case .generating = phase {
            return true
        }
        return false
    }

    /// True while a result from `generation` may still be applied.
    public func owns(generation passGeneration: Int) -> Bool {
        phase == .generating(generation: passGeneration)
    }

    @discardableResult
    public mutating func reduce(_ event: Event, now: Date, floor: TimeInterval) -> Effect {
        switch event {
        case .activity:
            switch phase {
            case .idle, .debouncing:
                return debounce(now)
            case .waitingFloor:
                // The pass at the end of the floor reads this line too.
                return .none
            case .generating:
                activityDuringPass = true
                return .none
            }

        case .timerFired:
            switch phase {
            case let .debouncing(until), let .waitingFloor(until):
                if now < until {
                    return .arm(at: until)
                }
                if let last = lastPassAt, now < last.addingTimeInterval(floor) {
                    let ready = last.addingTimeInterval(floor)
                    phase = .waitingFloor(until: ready)
                    return .arm(at: ready)
                }
                return startPass(now)
            case .idle, .generating:
                return .none
            }

        case .tick:
            if isGenerating {
                return .none
            }
            if let last = lastPassAt, now < last.addingTimeInterval(floor) {
                return .none
            }
            return startPass(now)

        case .passRequested:
            if isGenerating {
                return .none
            }
            return startPass(now)

        case let .passFinished(passGeneration, endMs):
            guard owns(generation: passGeneration) else { return .none }
            if let endMs {
                watermarkMs = endMs
            }
            if activityDuringPass {
                activityDuringPass = false
                return debounce(now)
            }
            phase = .idle
            return .none

        case let .passSkipped(passGeneration):
            guard owns(generation: passGeneration) else { return .none }
            lastPassAt = lastPassBeforeRun
            if activityDuringPass {
                activityDuringPass = false
                return debounce(now)
            }
            phase = .idle
            return .none

        case .cancelPending:
            switch phase {
            case .debouncing, .waitingFloor:
                phase = .idle
                return .disarm
            case .idle, .generating:
                return .none
            }

        case .stop:
            generation += 1
            phase = .idle
            activityDuringPass = false
            return .disarm

        case .reset:
            generation += 1
            phase = .idle
            watermarkMs = 0
            lastPassAt = nil
            lastPassBeforeRun = nil
            activityDuringPass = false
            return .disarm
        }
    }

    private mutating func debounce(_ now: Date) -> Effect {
        let until = now.addingTimeInterval(Self.quietWindow)
        phase = .debouncing(until: until)
        return .arm(at: until)
    }

    private mutating func startPass(_ now: Date) -> Effect {
        phase = .generating(generation: generation)
        lastPassBeforeRun = lastPassAt
        lastPassAt = now
        activityDuringPass = false
        return .startPass(generation: generation)
    }
}
