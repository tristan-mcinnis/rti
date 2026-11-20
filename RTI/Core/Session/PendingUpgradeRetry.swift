import Foundation

/// How long a queued transcript upgrade waits before RTI tries it again.
public enum PendingUpgradeRetry {
    public static let delays: [Duration] = [.seconds(600), .seconds(1800), .seconds(3600)]

    public static func delay(afterAttempt attempt: Int) -> Duration {
        delays[min(max(0, attempt), delays.count - 1)]
    }
}
