import Foundation

/// Tracks a session start that waits on the mic permission prompt.
///
/// `begin` hands out a token. A stop pressed meanwhile calls `cancel`, so the
/// permission answer, whenever it comes, fails `resolve` and starts nothing.
public struct PendingStartGate: Sendable {
    private var nextToken = 0
    private var pendingToken: Int?

    public init() {}

    public var isPending: Bool { pendingToken != nil }

    /// A token for a new pending start, or nil when one is already pending.
    public mutating func begin() -> Int? {
        guard pendingToken == nil else { return nil }
        nextToken += 1
        pendingToken = nextToken
        return nextToken
    }

    /// True when `token` is still the pending start, which it then clears.
    public mutating func resolve(_ token: Int) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        return true
    }

    /// Drops the pending start. True when one was pending.
    @discardableResult
    public mutating func cancel() -> Bool {
        defer { pendingToken = nil }
        return pendingToken != nil
    }
}
