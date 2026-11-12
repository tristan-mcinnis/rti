import Foundation

/// Groups streamed answer deltas before they reach the chat view. Each write
/// to the answer re-parses the whole Markdown, so writing every SSE delta
/// cost one full parse per token. The buffer is written at most every
/// `interval` (80 ms), at once at a paragraph break, and always when the
/// answer finishes, fails or is cancelled: the caller calls `flush` then.
/// The first delta is written at once, so the first word shows without delay.
public struct StreamCoalescer: Sendable {
    public static let defaultInterval: TimeInterval = 0.08

    public let interval: TimeInterval
    /// Text received but not yet written.
    public private(set) var pending = ""
    private var lastFlush: Date?

    public init(interval: TimeInterval = StreamCoalescer.defaultInterval) {
        self.interval = interval
    }

    /// Add one delta. Returns the text to write now, or nil to keep it
    /// buffered until a later delta, the caller's timer or `flush`.
    public mutating func append(_ delta: String, now: Date) -> String? {
        pending += delta
        let due = lastFlush.map { now.timeIntervalSince($0) >= interval } ?? true
        guard due || pending.contains("\n\n") else { return nil }
        return flush(now: now)
    }

    /// Everything buffered, which the caller must write. Empty when nothing
    /// waits.
    public mutating func flush(now: Date) -> String {
        let text = pending
        pending = ""
        if !text.isEmpty {
            lastFlush = now
        }
        return text
    }

    /// Drop the buffer and start over, for a new answer or a cleared one.
    public mutating func reset() {
        pending = ""
        lastFlush = nil
    }
}
