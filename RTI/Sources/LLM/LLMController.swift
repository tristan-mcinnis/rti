import Foundation
import GRDB

struct ChatEntry: Identifiable, Equatable {
    let id = UUID()
    let role: String           // "user" | "assistant"
    var text: String
    let action: String?        // "Ask" | "Assist" — user entries only
    let contextUsed: Bool      // user entries only
}

@MainActor
final class LLMController: ObservableObject {
    static let shared = LLMController()

    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var streaming = false
    @Published private(set) var lastError: String?
    @Published var smartMode: Bool = false

    private let client: KimiClient
    private var currentTask: Task<Void, Never>?
    private var streamingEntryID: UUID?

    private static let systemPrompt = """
    You are RTI, a real-time meeting assistant. The user is in an active conversation.
    Keep responses short (under 120 words), direct, and actionable. Use simple markdown
    where it helps (bullets, **bold** for key terms). If you don't know something, say so briefly.
    """

    private static let assistPrompt = "Based on the recent conversation, suggest what I should say or ask next. Be concise — max 3 short lines."

    private static let contextWindowSeconds: Double = 360

    private init() {
        self.client = KimiClient(apiKey: Secrets.kimiAPIKey, baseURL: Secrets.kimiBaseURL)
    }

    func sendAskAnything(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSend(userInput: trimmed, action: "Ask")
    }

    func sendAssist() {
        performSend(userInput: Self.assistPrompt, action: "Assist")
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        streaming = false
    }

    func clear() {
        cancel()
        entries = []
        lastError = nil
    }

    private func performSend(userInput: String, action: String) {
        currentTask?.cancel()
        lastError = nil

        let transcript = recentTranscriptText()
        let contextUsed = !transcript.isEmpty
        let fullContent = contextUsed
            ? "Recent conversation (last 6 minutes, diarized):\n\(transcript)\n\nUser question: \(userInput)"
            : userInput

        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: contextUsed))

        var kimiMessages: [KimiMessage] = [KimiMessage(role: "system", content: Self.systemPrompt)]
        for (idx, entry) in entries.enumerated() {
            let isLatestUser = idx == entries.count - 1 && entry.role == "user"
            let content = isLatestUser ? fullContent : entry.text
            // Kimi rejects empty-content messages (e.g. a placeholder from a failed prior stream).
            if content.isEmpty { continue }
            kimiMessages.append(KimiMessage(role: entry.role, content: content))
        }

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false)
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        streaming = true
        let thisEntryID = assistantEntry.id
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in client.streamChat(messages: kimiMessages, smart: smartMode) {
                    if Task.isCancelled { return }
                    self.appendToStreamingEntry(delta)
                }
            } catch {
                if Task.isCancelled { return }
                self.lastError = "\(error)"
                NSLog("[RTI] LLM stream error: \(error)")
            }
            guard self.streamingEntryID == thisEntryID else { return }
            self.streaming = false
            self.pruneTrailingEmptyAssistant()
            self.streamingEntryID = nil
        }
    }

    private func pruneTrailingEmptyAssistant() {
        if let last = entries.last, last.role == "assistant", last.text.isEmpty {
            entries.removeLast()
        }
    }

    private func appendToStreamingEntry(_ delta: String) {
        guard let id = streamingEntryID,
              let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text += delta
    }

    private func recentTranscriptText() -> String {
        guard let sessionId = SessionCoordinator.shared.currentSessionId,
              let startedAt = SessionCoordinator.shared.startedAt else {
            return ""
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let windowMs = Int(Self.contextWindowSeconds * 1000)
        let threshold = max(0, elapsedMs - windowMs)

        do {
            return try RTIDatabase.shared.pool.read { db in
                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .filter(Column("start_ms") >= threshold)
                    .order(Column("start_ms"))
                    .fetchAll(db)
                return entries.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
            }
        } catch {
            NSLog("[RTI] transcript fetch failed: \(error)")
            return ""
        }
    }
}
