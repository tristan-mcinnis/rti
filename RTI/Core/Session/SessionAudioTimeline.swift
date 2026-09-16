import Foundation

/// Both retained legs share a clock. Offsets describe capture start, not a
/// reason to choose one recording and silently omit the other.
public enum SessionAudioTimeline {
    public struct Leg: Equatable, Sendable {
        public let offset: TimeInterval
        public let duration: TimeInterval
        public init(offset: TimeInterval, duration: TimeInterval) {
            self.offset = offset
            self.duration = max(0, duration)
        }
    }
    public struct Start: Equatable, Sendable {
        public let index: Int
        public let sourceTime: TimeInterval
        public let delay: TimeInterval
    }
    public static func duration(of legs: [Leg]) -> TimeInterval {
        let origin = min(0, legs.map(\.offset).min() ?? 0)
        return legs.map { $0.offset - origin + $0.duration }.max() ?? 0
    }
    public static func starts(at position: TimeInterval, legs: [Leg]) -> [Start] {
        let origin = min(0, legs.map(\.offset).min() ?? 0)
        let position = max(0, position)
        return legs.enumerated().compactMap { index, leg in
            let offset = leg.offset - origin
            guard position < offset + leg.duration else { return nil }
            return Start(index: index, sourceTime: max(0, position - offset), delay: max(0, offset - position))
        }
    }
}
