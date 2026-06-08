import Foundation

/// Drives periodic analysis tasks (notes generation,
/// discussion-guide matching) on a configurable timer. Owns the Timer,
/// interval config, per-task enabled-checks, and per-task watermarks.
/// SessionCoordinator starts/stops the scheduler — individual controllers
/// register their analysis closures once at launch.
@MainActor
final class AnalysisScheduler {
    static let shared = AnalysisScheduler()

    /// A single analysis task registered with the scheduler.
    struct AnalysisTask {
        /// UserDefaults key that gates whether this task fires.
        let enabledKey: String
        /// Called on each timer tick. Receives the last watermark
        /// (nil on first fire) and returns the new watermark (nil if
        /// no entries were processed). The scheduler stores the
        /// returned watermark and passes it as `sinceMs` next time.
        let execute: @MainActor (_ sinceMs: Int?) async -> Int?
    }

    private var tasks: [String: AnalysisTask] = [:]
    private var watermarks: [String: Int] = [:]
    private var timer: Timer?
    private var currentInterval: TimeInterval = 120

    private init() {}

    /// Register a periodic analysis task. Call once per task lifetime
    /// (typically at app launch). The scheduler stores the watermark
    /// internally so callers don't need to track it.
    func register(id: String, task: AnalysisTask) {
        tasks[id] = task
        watermarks[id] = 0
    }

    func unregister(id: String) {
        tasks.removeValue(forKey: id)
        watermarks.removeValue(forKey: id)
    }

    /// Start the analysis timer. Resets all watermarks to zero (fresh
    /// session) and reads the interval + per-task enabled flags from
    /// UserDefaults on each tick so Settings changes take effect
    /// without restarting the timer.
    func start(intervalKey: String, defaultInterval: TimeInterval) {
        timer?.invalidate()
        for key in watermarks.keys { watermarks[key] = 0 }

        let interval = UserDefaults.standard.double(forKey: intervalKey)
        currentInterval = interval > 0 ? interval : defaultInterval

        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer?.tolerance = 5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    private func fire() {
        for (id, task) in tasks {
            let enabled = UserDefaults.standard.object(forKey: task.enabledKey) as? Bool ?? true
            guard enabled else { continue }
            let sinceMs = watermarks[id] == 0 ? nil : watermarks[id]
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let newEndMs = await task.execute(sinceMs) {
                    self.watermarks[id] = newEndMs
                }
            }
        }
    }
}
