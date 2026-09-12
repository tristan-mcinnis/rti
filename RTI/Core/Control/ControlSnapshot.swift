import Foundation

/// What the control socket knows about the live session.
///
/// The listener answers `status` straight out of this value, so a status
/// request never reaches the main actor and never waits on the audio path.
/// The main actor writes a fresh snapshot on every phase change; the socket
/// thread only ever reads one.
///
/// The elapsed readout is held as a *clock*, not a rendered string, so a
/// snapshot taken once at the start of a recording still answers "Recording,
/// 12:43" twelve minutes later without anything having to tick.
public struct ControlSnapshot: Equatable, Sendable {

    /// How the elapsed readout moves. `.running` counts up from an anchor
    /// (already adjusted for any paused spans); `.frozen` stands still.
    public enum Clock: Equatable, Sendable {
        case none
        case running(since: Date)
        case frozen(TimeInterval)
    }

    /// A session is live — recording *or* paused. Matches the app's
    /// `isRunning`, so `stop` stays available while paused.
    public var recording: Bool
    /// Capture is suspended. Only true inside a live session.
    public var paused: Bool
    /// Mid-transition (flushing the stop, or summarizing). A command that
    /// arrives now is a no-op, so the caller is told the app is busy.
    public var busy: Bool
    /// The human phrase, without the clock: "Idle", "Recording", "Paused".
    public var label: String
    public var clock: Clock

    public init(
        recording: Bool = false,
        paused: Bool = false,
        busy: Bool = false,
        label: String = "Idle",
        clock: Clock = .none
    ) {
        self.recording = recording
        self.paused = paused
        self.busy = busy
        self.label = label
        self.clock = clock
    }

    public static let idle = ControlSnapshot()

    /// The session state the socket should report, as a pure function of the
    /// phase and the captured-time elapsed. Kept here rather than in the app
    /// module so every phase's answer is unit-testable.
    public static func forSession(phase: SessionPhase, elapsed: TimeInterval, now: Date) -> ControlSnapshot {
        switch phase {
        case .idle:
            return ControlSnapshot(label: "Idle")
        case .recording:
            return ControlSnapshot(
                recording: true,
                label: "Recording",
                clock: .running(since: now.addingTimeInterval(-elapsed))
            )
        case .paused:
            return ControlSnapshot(recording: true, paused: true, label: "Paused", clock: .frozen(elapsed))
        case .finishing:
            return ControlSnapshot(busy: true, label: "Finishing", clock: .frozen(elapsed))
        case .summarizing:
            return ControlSnapshot(busy: true, label: "Summarizing", clock: .frozen(elapsed))
        case .done:
            return ControlSnapshot(label: "Notes ready", clock: .frozen(elapsed))
        }
    }

    public func elapsed(at now: Date) -> TimeInterval? {
        switch clock {
        case .none: return nil
        case .running(let since): return max(0, now.timeIntervalSince(since))
        case .frozen(let interval): return max(0, interval)
        }
    }

    /// One short human phrase, shown verbatim by the caller: "Recording, 12:43".
    public func detail(at now: Date) -> String {
        guard let elapsed = elapsed(at: now) else { return label }
        return "\(label), \(TimeFormat.elapsed(elapsed))"
    }

    /// The contract's status document, as the single JSON line `status` replies
    /// with. Keys are sorted so the line is byte-stable for a given state.
    public func statusLine(app: String = ControlManifest.appID, at now: Date = Date()) -> String {
        let document: [String: Any] = [
            "app": app,
            "ok": true,
            "busy": busy,
            "recording": recording,
            "paused": paused,
            "detail": detail(at: now),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            // Unreachable with the fixed shape above, but a status reply must
            // always be one well-formed line — never an empty one.
            return #"{"app":"\#(app)","busy":false,"detail":"Unavailable","ok":false,"paused":false,"recording":false}"#
        }
        return line
    }
}
