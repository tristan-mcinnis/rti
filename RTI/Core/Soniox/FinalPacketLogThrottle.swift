import Foundation

/// Decides which Soniox packets with final tokens get a log line. Each
/// leg's client owns one. Logging every packet wrote 1.2k to 3.1k lines an
/// hour on the main actor; the first packet and then every 100th still show
/// that the leg is alive.
public struct FinalPacketLogThrottle: Sendable {
    public static let every = 100

    /// Packets with final tokens seen so far.
    public private(set) var count = 0
    private let every: Int

    public init(every: Int = FinalPacketLogThrottle.every) {
        self.every = max(1, every)
    }

    /// Count one packet with final tokens. True when this packet gets a log
    /// line: the first one, then every `every`th.
    public mutating func record() -> Bool {
        count += 1
        return count == 1 || count.isMultiple(of: every)
    }
}
