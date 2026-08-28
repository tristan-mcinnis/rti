import Foundation

/// One materially changed active-screen OCR snapshot captured during a live
/// RTI session. Only text and its session-relative timestamp survive; the
/// screenshot is discarded immediately after on-device OCR.
public struct VisualContextEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let offsetSeconds: Int
    public let text: String

    public init(id: UUID = UUID(), offsetSeconds: Int, text: String) {
        self.id = id
        self.offsetSeconds = max(0, offsetSeconds)
        self.text = text
    }
}

/// Pure text shaping shared by the live sampler, prompt injection, archive,
/// and tests. Keeping this deterministic avoids an extra model call every
/// minute and makes the capture boundary easy to reason about.
public enum VisualContextText {
    public static func compact(_ text: String, maxCharacters: Int = 1_800) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleaned = lines.joined(separator: "\n")
        guard cleaned.count > maxCharacters else { return cleaned }
        return String(cleaned.prefix(maxCharacters)) + "\n…[truncated]"
    }

    /// OCR shifts slightly between frames. Treat two captures as the same when
    /// their normalized word sets overlap by at least `similarityThreshold`.
    public static func isMeaningfullyDifferent(
        _ candidate: String,
        from previous: String?,
        similarityThreshold: Double = 0.78
    ) -> Bool {
        let candidateTokens = tokens(candidate)
        guard candidateTokens.count >= 3 else { return false }
        guard let previous else { return true }

        let previousTokens = tokens(previous)
        guard !previousTokens.isEmpty else { return true }
        let union = candidateTokens.union(previousTokens)
        guard !union.isEmpty else { return false }
        let overlap = candidateTokens.intersection(previousTokens)
        return Double(overlap.count) / Double(union.count) < similarityThreshold
    }

    public static func promptContext(
        events: [VisualContextEvent],
        maxEvents: Int = 3,
        maxCharacters: Int = 5_000
    ) -> String? {
        guard maxEvents > 0, maxCharacters > 0 else { return nil }
        let blocks = events.suffix(maxEvents).map { event in
            "[\(timestamp(event.offsetSeconds))]\n\(event.text)"
        }
        let body = blocks.joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }
        let capped = body.count > maxCharacters
            ? String(body.suffix(maxCharacters))
            : body
        return "Live visual context from the active screen. OCR may contain errors; use it as supporting context, not as something a participant said.\n\n\(capped)"
    }

    public static func timestamp(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    private static func tokens(_ text: String) -> Set<String> {
        let normalized = String(text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        })
        let words: [String] = normalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return Set(words)
    }
}
