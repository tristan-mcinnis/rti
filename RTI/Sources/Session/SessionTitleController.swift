import Foundation

@MainActor
final class SessionTitleController: ObservableObject {
    static let shared = SessionTitleController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

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

        let messages = [LLMMessage(role: "user", content: Self.titlePrompt + "\n" + transcript)]

        guard let response = await request.collectAsync(messages: messages, smart: false) else {
            isGenerating = false
            return nil
        }
        let title = Self.parseFirstTitle(from: response) ?? Self.fallbackTitle
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

    private static let titlePattern1 = try! NSRegularExpression(pattern: "^\\d+\\.\\s+(.+)")
    private static let titlePattern2 = try! NSRegularExpression(pattern: "^\\d+\\)\\s+(.+)")
    private static let titlePattern3 = try! NSRegularExpression(pattern: "^\\-\\s+(.+)")

    static func parseFirstTitle(from response: String) -> String? {
        let lines = response.components(separatedBy: "\n")
        let patterns = [titlePattern1, titlePattern2, titlePattern3]
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
