import Foundation
import os

/// Signposts for the main-thread work that grows with a live call: pass
/// preparation, the checkpoint snapshot and transcript flushes. Instruments
/// shows them under the `LivePerf` category. The last duration of each
/// interval is also kept, so a test can assert a budget without Instruments.
public enum PassSignpost {
    private static let signposter = OSSignposter(subsystem: "com.tristan.rti.personal", category: "LivePerf")
    private static let durations = OSAllocatedUnfairLock(initialState: [String: Double]())

    /// Run `body` inside a named signpost interval and record its duration.
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let key = name.description
            durations.withLock { $0[key] = elapsed }
        }
        return try body()
    }

    /// The last recorded duration of `name`, in milliseconds.
    public static func lastMilliseconds(_ name: String) -> Double? {
        durations.withLock { $0[name] }
    }
}
