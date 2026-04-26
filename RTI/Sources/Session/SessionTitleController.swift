import Foundation
import GRDB

@MainActor
final class SessionTitleController: ObservableObject {
    static let shared = SessionTitleController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let client: DeepSeekClient

    private init() {
        self.client = DeepSeekClient(baseURL: Secrets.deepseekBaseURL)
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

    func generateTitle(for sessionId: String) async {
        guard !isGenerating else { return }
        isGenerating = true
        lastError = nil

        defer { isGenerating = false }

        let transcript: String
        do {
            transcript = try await RTIDatabase.shared.pool.read { db in
                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)
                return entries.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
            }
        } catch {
            lastError = "Failed to load transcript: \(error)"
            NSLog("[RTI] SessionTitle transcript load failed: \(error)")
            return
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let messages = [DeepSeekMessage(role: "user", content: Self.titlePrompt + "\n" + transcript)]
        var fullResponse = ""

        do {
            for try await delta in client.streamChat(messages: messages, smart: false) {
                fullResponse += delta
            }
        } catch {
            lastError = "Title generation failed: \(error)"
            NSLog("[RTI] SessionTitle stream error: \(error)")
            return
        }

        let title = Self.parseFirstTitle(from: fullResponse) ?? Self.fallbackTitle
        do {
            try await RTIDatabase.shared.pool.write { db in
                if var session = try Session.fetchOne(db, key: sessionId) {
                    session.title = title
                    try session.update(db)
                }
            }
        } catch {
            NSLog("[RTI] SessionTitle save failed: \(error)")
        }
    }

    private static var fallbackTitle: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return "Meeting at \(df.string(from: Date()))"
    }

    static func parseFirstTitle(from response: String) -> String? {
        let lines = response.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match "1. Title Here" or "1) Title Here" or "- Title Here"
            let patterns = [
                try? NSRegularExpression(pattern: "^\\d+\\.\\s+(.+)"),
                try? NSRegularExpression(pattern: "^\\d+\\)\\s+(.+)"),
                try? NSRegularExpression(pattern: "^\\-\\s+(.+)"),
            ]
            for pattern in patterns {
                guard let pattern = pattern else { continue }
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
