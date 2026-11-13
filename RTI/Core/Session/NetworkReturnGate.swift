import Foundation

/// Says when the network has come back: true only on a change from
/// unavailable to available. The first report sets the state and is never a
/// return, so launch does not count as one (launch runs its own resume).
public struct NetworkReturnGate: Sendable {
    private var lastAvailable: Bool?

    public init() {}

    /// Record the path status; true when it just became available again.
    public mutating func update(available: Bool) -> Bool {
        defer { lastAvailable = available }
        return available && lastAvailable == false
    }
}
