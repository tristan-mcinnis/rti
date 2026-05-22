import Foundation
import Observation

@Observable @MainActor
final class SessionTitleController {
    static let shared = SessionTitleController()

    private(set) var isGenerating = false
    private(set) var lastError: String?

    private let request: LLMRequest
    /// Per-session in-memory cache. `CorpusManager.renderSession` reads
    /// the title here at session-end and embeds it in the markdown
    /// frontmatter; once the file is written the cache entry is purged.
    private var cache: [String: String] = [:]

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    private static let titlePrompt = """
    You are an assistant that creates concise meeting titles from transcript text.

    Task:
    Generate exactly 5 possible meeting names based on the transcript.

    Requirements:
    - 3-8 words each
    - Clear, specific, and professional
    - Capture the main topic and intent (decision, planning, review, kickoff, etc.)
    - Avoid vague titles like "Team Meeting" or "Discussion"
    - Do not include dates, participant names, or company-internal codes unless explicitly central
    - Use title case
    - Avoid duplicates

    Output format:
    Return only a numbered list of 5 titles. No explanations.

    Transcript:
    """

    func cancel() {
        request.cancel()
        isGenerating = false
    }

    @discardableResult
    func generateTitle(for sessionId: String) async -> String? {
        guard !isGenerating else { return cache[sessionId] }
        cancel()
        isGenerating = true
        lastError = nil

        let transcript = TranscriptContext.text(forSessionId: sessionId)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isGenerating = false
            return nil
        }

        // Pre-seed the cache with a transcript-derived fallback so that even
        // if the LLM call fails or the task is cancelled mid-flight, the
        // markdown render still has a meaningful title to embed in
        // frontmatter.
        let seed = Self.fallbackTitle(fromTranscript: transcript)
        cache[sessionId] = seed

        let messages = [LLMMessage(role: "user", content: Self.titlePrompt + "\n" + transcript)]

        let response = await request.collectAsync(messages: messages, smart: false)
        let title: String
        if let response, let parsed = Self.parseFirstTitle(from: response) {
            title = parsed
        } else {
            if response == nil {
                RTILog.log("SessionTitleController: LLM returned no response for \(sessionId), using fallback", category: "session-title")
                lastError = "Title generation failed; using fallback."
            } else {
                RTILog.log("SessionTitleController: parse failed for \(sessionId), using fallback", category: "session-title")
            }
            title = seed
        }
        cache[sessionId] = title
        isGenerating = false
        return title
    }

    /// In-memory lookup used by `CorpusManager` and any UI that wants the
    /// most recently generated title for a session id during this app
    /// lifetime. Falls back to nil — callers reading post-restart
    /// titles should read frontmatter via `CorpusBackedStore`.
    func cachedTitle(forSessionId id: String) -> String? {
        cache[id]
    }

    /// Called by `CorpusManager` after a successful markdown render so
    /// the cache doesn't grow unbounded.
    func purgeCache(forSessionId id: String) {
        cache.removeValue(forKey: id)
    }

    private static var fallbackTitle: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return "Meeting at \(df.string(from: Date()))"
    }

    /// Build a fallback title from the first words of the transcript. Used
    /// whenever the LLM call fails or returns unparsable output — better
    /// than a bare timestamp because it carries some signal about content.
    static func fallbackTitle(fromTranscript transcript: String) -> String {
        let stripped = transcript
            .split(separator: "\n")
            .map { line -> String in
                // Strip leading speaker tags like "self:" / "[user note]:".
                if let colon = line.firstIndex(of: ":") {
                    return String(line[line.index(after: colon)...])
                }
                return String(line)
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(8)
            .map(String.init)
        guard !words.isEmpty else { return fallbackTitle }
        var title = words.joined(separator: " ")
        // Trim trailing punctuation for cleaner display.
        while let last = title.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last) {
            title = String(title.unicodeScalars.dropLast())
        }
        return title.isEmpty ? fallbackTitle : title
    }

    /// Patterns the LLM uses for numbered/bulleted title suggestions.
    /// `compileRegex` returns nil for an invalid pattern; an invalid literal
    /// here is a programmer error caught at first call, not a crash hazard.
    private static let titlePatterns: [NSRegularExpression] = [
        "^\\d+\\.\\s+(.+)",
        "^\\d+\\)\\s+(.+)",
        "^\\-\\s+(.+)"
    ].compactMap { compileRegex($0) }

    private static func compileRegex(_ pattern: String) -> NSRegularExpression? {
        do { return try NSRegularExpression(pattern: pattern) }
        catch {
            RTILog.log("titlePattern compile failed for \(pattern): \(error)", category: "session-title")
            return nil
        }
    }

    static func parseFirstTitle(from response: String) -> String? {
        let lines = response.components(separatedBy: "\n")
        let patterns = titlePatterns
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in patterns {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = pattern.firstMatch(in: trimmed, range: range),
                   let captureRange = Range(match.range(at: 1), in: trimmed) {
                    let title = String(trimmed[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, title.count >= 3 {
                        return title
                    }
                }
            }
        }
        return nil
    }
}
