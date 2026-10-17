import Foundation

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
        let enabledKey: String
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
        timer?.invalidate()
        runGeneration += 1
        for key in watermarks.keys { watermarks[key] = 0 }

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

    private func fire() {
        for (id, task) in tasks {
            let enabled = UserDefaults.standard.object(forKey: task.enabledKey) as? Bool ?? false
            guard enabled else { continue }
            let sinceMs = watermarks[id] == 0 ? nil : watermarks[id]
            let tickGeneration = runGeneration
            let key = UUID()
            inFlight[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.inFlight.removeValue(forKey: key) }
                if let newEndMs = await task.execute(sinceMs),
                   !Task.isCancelled, tickGeneration == self.runGeneration {
                    self.watermarks[id] = newEndMs
                }
            }
        }
    }
}
