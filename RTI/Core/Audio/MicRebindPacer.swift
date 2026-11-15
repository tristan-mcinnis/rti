import Foundation

/// When a mic configuration change should rebind the engine (2026-11-15).
/// A burst of changes waits `mergeDelay` and becomes one rebind. A change
/// within `settle` of RTI's own rebind is its echo (a fresh engine re-sets
/// the client rate) and is dropped. More than `burstLimit` rebinds inside
/// `burstWindow` back off to `backoff` before the next one.
public struct MicRebindPacer: Sendable, Equatable {
    public static let mergeDelay: TimeInterval = 0.3
    public static let settle: TimeInterval = 1.0
    public static let burstLimit = 3
    public static let burstWindow: TimeInterval = 10
    public static let backoff: TimeInterval = 5

    /// Times of recent rebinds, oldest first.
    public private(set) var recent: [TimeInterval] = []

    public init() {}

    /// Seconds to wait before rebinding for a change seen at `now`, or nil
    /// to drop it.
    public func delay(now: TimeInterval) -> TimeInterval? {
        if let last = recent.last, now - last < Self.settle {
            return nil
        }
        let inWindow = recent.filter { now - $0 < Self.burstWindow }
        return inWindow.count >= Self.burstLimit ? Self.backoff : Self.mergeDelay
    }

    public mutating func didRebind(at time: TimeInterval) {
        recent.append(time)
        recent.removeAll { time - $0 >= Self.burstWindow }
    }
}
