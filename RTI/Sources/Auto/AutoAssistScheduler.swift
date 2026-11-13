import Foundation
import RTICore

/// Drives the periodic Auto-mode tick on a timer. Owns the Timer, the
/// per-task enabled-check, and the per-task watermark. SessionCoordinator
/// starts/stops the scheduler; the task registers its closure once at
/// launch.
@MainActor
final class AutoAssistScheduler {
    static let shared = AutoAssistScheduler()

    /// A single task registered with the scheduler.
    struct ScheduledTask {
        /// UserDefaults key that gates whether this task fires.
        let enabledKey: String?
        /// A session-bound feature may run independently of a global preference.
        var sessionEnabled: @MainActor () -> Bool = { false }
        /// Where in the interval this task starts, as a fraction from 0
        /// to 1. Tasks with different phases never prepare their prompts on
        /// the same main-thread turn (2026-11-13 M1 audit: three or four
        /// pass builds back to back on each tick).
        var phase: Double = 0
        /// Called on each timer tick. Receives the last watermark
        /// (nil on first fire) and returns the new watermark (nil if
        /// no entries were processed). The scheduler stores the
        /// returned watermark and passes it as `sinceMs` next time.
        let execute: @MainActor (_ sinceMs: Int?) async -> Int?
    }

    private var tasks: [String: ScheduledTask] = [:]
    private var watermarks: [String: Int] = [:]
    private var timer: Timer?

    private init() {}

    /// Register a periodic task. Call once per task lifetime
    /// (typically at app launch). The scheduler stores the watermark
    /// internally so callers don't need to track it.
    func register(id: String, task: ScheduledTask) {
        tasks[id] = task
        watermarks[id] = 0
    }

    func unregister(id: String) {
        tasks.removeValue(forKey: id)
        watermarks.removeValue(forKey: id)
    }

    /// Start the timer. Resets all watermarks to zero (fresh session) and
    /// reads the per-task enabled flags from UserDefaults on each tick so
    /// Settings changes take effect without restarting the timer.
    func start(interval: TimeInterval) {
        runGeneration += 1
        for key in watermarks.keys { watermarks[key] = 0 }
        schedule(interval)
    }

    func updateInterval(_ interval: TimeInterval) {
        guard let timer, timer.timeInterval != interval else { return }
        schedule(interval)
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer?.tolerance = 5
    }

    func stop() {
        runGeneration += 1
        for task in inFlight.values { task.cancel() }
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    /// Bumped on start/stop so a tick finishing after a restart cannot write
    /// its end-ms into the new session's watermark.
    private var runGeneration = 0

    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Wait (without blocking the main thread) for cancelled passes to wind
    /// down, up to `timeout`.
    func drainInFlight(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !inFlight.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Each task's delay after a tick: its phase times the interval.
    func offsets(interval: TimeInterval) -> [String: TimeInterval] {
        tasks.mapValues { min(max($0.phase, 0), 0.95) * interval }
    }

    private static func isEnabled(_ task: ScheduledTask) -> Bool {
        let enabled = task.enabledKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false
        return enabled || task.sessionEnabled()
    }

    private func fire() {
        let interval = timer?.timeInterval ?? NotesSettings.tickInterval
        let offsets = offsets(interval: interval)
        for (id, task) in tasks {
            guard Self.isEnabled(task) else { continue }
            let tickGeneration = runGeneration
            let delay = offsets[id] ?? 0
            let key = UUID()
            inFlight[key] = Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard let self else { return }
                defer { self.inFlight.removeValue(forKey: key) }
                // A stop, restart or toggle during the wait drops this run.
                guard !Task.isCancelled, tickGeneration == self.runGeneration,
                      delay == 0 || Self.isEnabled(task) else { return }
                let sinceMs = self.watermarks[id] == 0 ? nil : self.watermarks[id]
                if let newEndMs = await task.execute(sinceMs),
                   !Task.isCancelled, tickGeneration == self.runGeneration {
                    self.watermarks[id] = newEndMs
                }
            }
        }
    }
}
