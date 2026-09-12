import Foundation

/// The menu-bar status item's refresh policy, kept pure so it can be tested
/// without a status bar.
///
/// The status item used to hold a 1 Hz repeating timer for the life of the
/// app, recording or not: ~86,400 main-thread wakeups a day to recompute a
/// glyph, a tooltip and a title that had not changed. The readout only moves
/// while the clock actually runs, so the timer now belongs to the recording
/// phase alone; every other transition already arrives through AppDelegate's
/// session-phase observation.
public enum MenuStatusTick {

    /// Phases whose status item carries the elapsed readout ("3:07").
    public static func showsElapsed(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .recording, .paused, .finishing: true
        case .idle, .summarizing, .done: false
        }
    }

    /// Phases that need a repeating timer. Only `.recording` advances the
    /// readout: `.paused` freezes it (`elapsed` subtracts the open paused
    /// span) and `.finishing` is measured against the frozen `endedAt`, so
    /// both are drawn once by the phase observation and then stand still.
    public static func needsRepeatingTimer(_ phase: SessionPhase) -> Bool {
        phase == .recording
    }

    /// One tick a second — the readout's smallest step is a second.
    public static let interval: TimeInterval = 1

    /// Slack the scheduler may use to coalesce this tick with other wakeups.
    /// A quarter of the smallest visible step: large enough that the timer
    /// joins a nearby wakeup instead of forcing its own (timer coalescing
    /// needs a non-zero tolerance), small enough that the seconds digit can
    /// never look like it skipped or stalled.
    public static let tolerance: TimeInterval = 0.25
}
