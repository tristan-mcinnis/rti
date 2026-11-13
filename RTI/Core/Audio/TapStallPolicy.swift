import Foundation

/// When a CoreAudio process tap that delivers no buffers is rebuilt.
///
/// A tap on a Bluetooth output stops delivering buffers whenever nothing
/// plays, so "no buffers" is often an idle leg, not a dead one. The tap never
/// gives up: three quick rebuilds, then one every `slowInterval` for as long
/// as the silence lasts. Any buffer after the last rebuild restarts the quick
/// attempts. A pure value so the stall clock can be tested without a device.
public struct TapStallPolicy: Sendable, Equatable {
    public static let timeout: TimeInterval = 6
    public static let fastAttempts = 3
    public static let slowInterval: TimeInterval = 60

    /// The last rebuild (or the start); silence is measured from here or
    /// from the last buffer, whichever is later.
    public private(set) var reference: Date
    /// Rebuilds since the last buffer.
    public private(set) var attempts = 0

    public init(startedAt: Date) {
        reference = startedAt
    }

    /// The rebuild attempt number to run now, or nil. The caller rebuilds
    /// (and on failure simply waits for the next check); the policy has
    /// already moved its reference to `now`.
    public mutating func check(now: Date, lastBufferAt: Date?) -> Int? {
        if let last = lastBufferAt, last > reference {
            attempts = 0
            reference = last
        }
        let wait = attempts < Self.fastAttempts ? Self.timeout : Self.slowInterval
        guard now.timeIntervalSince(reference) >= wait else { return nil }
        attempts += 1
        reference = now
        return attempts
    }
}
