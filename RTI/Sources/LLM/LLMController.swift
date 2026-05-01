import Foundation
import GRDB

struct ChatEntry: Identifiable, Equatable {
    let id = UUID()
    let role: String           // "user" | "assistant"
    var text: String
    let action: String?        // "Ask" | "Assist" — user entries only
    let contextUsed: Bool      // user entries only — transcript attached
    let screenContextUsed: Bool // user entries only — OCR screen attached
}

@MainActor
final class LLMController: ObservableObject {
    static let shared = LLMController()

    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var streaming = false
    @Published private(set) var reasoning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorIsAuth: Bool = false
    @Published private(set) var pendingScreenContext: String?
    @Published var smartMode: Bool {
        didSet { UserDefaults.standard.set(smartMode, forKey: Self.smartModeKey) }
    }

    private let client: DeepSeekClient
    private var currentTask: Task<Void, Never>?
    private var streamingEntryID: UUID?

    private static let smartModeKey = "rti.llm.smartMode"

    private static let systemPrompt = """
    You are RTI, a real-time meeting assistant. The user is in an active conversation.
    Keep responses short (under 120 words), direct, and actionable. Use simple markdown
    where it helps (bullets, **bold** for key terms). If you don't know something, say so briefly.
    """

    private static let assistPrompt = "Based on the recent conversation, suggest what I should say or ask next. Be concise — max 3 short lines."
    private static let saySomethingPrompt = "Given the conversation so far, draft exactly one short reply I could say next. One line, natural, in my voice. No preamble."
    private static let followupsPrompt = "List 3 thoughtful follow-up questions I could ask the other person right now. Bullet points, one line each."
    private static let recapPrompt = "Recap the conversation so far in 3–5 short bullets: what was discussed, decisions, open items."

    private static let contextWindowSeconds: Double = 360

    private init() {
        self.smartMode = UserDefaults.standard.bool(forKey: Self.smartModeKey)
        self.client = DeepSeekClient(baseURL: Secrets.deepseekBaseURL)
        self.client.onReasoning = { [weak self] _ in
            self?.reasoning = true
        }
    }

    func sendAskAnything(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSend(userInput: trimmed, action: "Ask")
    }

    func sendAssist() {
        performSend(userInput: Self.assistPrompt, action: "Assist")
    }

    func sendSaySomething() {
        performSend(userInput: Self.saySomethingPrompt, action: "Say next")
    }

    func sendFollowupQuestions() {
        performSend(userInput: Self.followupsPrompt, action: "Follow-ups")
    }

    func sendRecap() {
        performSend(userInput: Self.recapPrompt, action: "Recap")
    }

    func attachScreenContext(_ text: String) {
        pendingScreenContext = text
        lastError = nil
        lastErrorIsAuth = false
    }

    func setScreenAttachError(_ message: String) {
        lastError = message
        lastErrorIsAuth = false
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        streaming = false
        reasoning = false
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages. Used when starting/resuming a session
    /// where the user expects history to remain on disk.
    func resetMemory() {
        cancel()
        entries = []
        lastError = nil
        lastErrorIsAuth = false
    }

    /// Destructive: in-memory reset PLUS deletion of chat_messages for the
    /// current session. Wired to the menubar "Clear Current Chat" action.
    func clear() {
        resetMemory()
        SessionCoordinator.shared.clearCurrentSessionMessages()
    }

    func loadHistoryForCurrentSession() {
        guard let sid = SessionCoordinator.shared.currentSessionId else { return }
        do {
            let rows = try RTIDatabase.shared.pool.read { db in
                try ChatMessage
                    .filter(Column("session_id") == sid)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            entries = rows.compactMap { row in
                guard row.role == "user" || row.role == "assistant" else { return nil }
                return ChatEntry(
                    role: row.role,
                    text: row.content,
                    action: row.action,
                    contextUsed: row.hadTranscriptContext,
                    screenContextUsed: row.hadScreenContext
                )
            }
        } catch {
            NSLog("[RTI] loadHistoryForCurrentSession failed: \(error)")
        }
    }

    private func persistMessage(sessionId: String, role: String, action: String?, content: String, hadTranscript: Bool, hadScreen: Bool) {
        let msg = ChatMessage(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: role,
            action: action,
            content: content,
            hadScreenContext: hadScreen,
            hadTranscriptContext: hadTranscript,
            createdAt: Date()
        )
        do {
            try RTIDatabase.shared.pool.write { db in try msg.insert(db) }
        } catch {
            NSLog("[RTI] persist chat_message failed: \(error)")
        }
    }

    private func performSend(userInput: String, action: String) {
        currentTask?.cancel()
        lastError = nil
        lastErrorIsAuth = false

        let transcript = recentTranscriptText()
        let contextUsed = !transcript.isEmpty
        let fullContent = contextUsed
            ? "Recent conversation (last 6 minutes, diarized):\n\(transcript)\n\nUser question: \(userInput)"
            : userInput

        let screenContext = pendingScreenContext
        pendingScreenContext = nil
        let screenContextUsed = screenContext != nil

        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: contextUsed, screenContextUsed: screenContextUsed))

        let persistSessionId = SessionCoordinator.shared.currentSessionId
        if let persistSessionId {
            persistMessage(sessionId: persistSessionId, role: "user", action: action, content: userInput, hadTranscript: contextUsed, hadScreen: screenContextUsed)
        }

        let activeMode = ModeStore.shared.activeMode
        let basePrompt: String = {
            if let prompt = activeMode?.systemPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prompt
            }
            return Self.systemPrompt
        }()

        var apiMessages: [DeepSeekMessage] = [DeepSeekMessage(role: "system", content: basePrompt)]
        if let reference = activeMode?.referenceText, !reference.isEmpty {
            let capped = reference.count > 8000 ? String(reference.prefix(8000)) + "\n…[truncated]" : reference
            let modeName = activeMode?.name ?? "active mode"
            apiMessages.append(DeepSeekMessage(
                role: "system",
                content: "Reference material attached to the active mode '\(modeName)'. Use it when relevant.\n---\n\(capped)\n---"
            ))
        }
        if let screenContext {
            apiMessages.append(DeepSeekMessage(
                role: "system",
                content: "User attached a screenshot. OCR text from the screen follows. Treat it as what the user is looking at.\n---\n\(screenContext)\n---"
            ))
        }
        for (idx, entry) in entries.enumerated() {
            let isLatestUser = idx == entries.count - 1 && entry.role == "user"
            let content = isLatestUser ? fullContent : entry.text
            // Skip non-final entries with empty content, but never skip the
            // last user entry — the API needs at least one user message.
            if content.isEmpty, !isLatestUser { continue }
            apiMessages.append(DeepSeekMessage(role: entry.role, content: content))
        }

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        streaming = true
        reasoning = false
        let thisEntryID = assistantEntry.id
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in client.streamChat(messages: apiMessages, smart: smartMode) {
                    if Task.isCancelled { return }
                    // First content delta means reasoning is over.
                    if self.reasoning { self.reasoning = false }
                    self.appendToStreamingEntry(delta)
                }
            } catch {
                if Task.isCancelled { return }
                if let api = error as? DeepSeekError {
                    switch api {
                    case .unauthorized:
                        self.lastError = "DeepSeek rejected the API key (401). Open Settings to paste a valid key."
                        self.lastErrorIsAuth = true
                    case .missingAPIKey:
                        self.lastError = "No DeepSeek API key set. Open Settings to add one."
                        self.lastErrorIsAuth = true
                    case .httpError(let code, let body):
                        self.lastError = "DeepSeek error \(code): \(body.prefix(300))"
                    case .streamError(let detail):
                        self.lastError = "DeepSeek stream error: \(detail.prefix(300))"
                    case .badResponse:
                        self.lastError = "DeepSeek returned an unexpected response."
                    }
                } else {
                    self.lastError = "\(error)"
                }
                NSLog("[RTI] LLM stream error: \(error)")
                RTILog.log("stream error: \(error)", category: "deepseek")
            }
            guard self.streamingEntryID == thisEntryID else { return }
            self.streaming = false
            self.reasoning = false
            self.pruneTrailingEmptyAssistant()
            self.streamingEntryID = nil

            // Re-read session ID after stream completes to avoid persisting
            // the assistant response to a stale session.
            let finalSessionId = SessionCoordinator.shared.currentSessionId ?? persistSessionId
            if let finalSessionId,
               let finalText = self.entries.last(where: { $0.id == thisEntryID })?.text,
               !finalText.isEmpty {
                self.persistMessage(sessionId: finalSessionId, role: "assistant", action: nil, content: finalText, hadTranscript: false, hadScreen: false)
            }
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
                return entries.map { e in
                    e.speakerId == "note"
                        ? "[user note]: \(e.text)"
                        : "\(e.speakerId): \(e.text)"
                }.joined(separator: "\n")
            }
        } catch {
            NSLog("[RTI] transcript fetch failed: \(error)")
            return ""
        }
    }
}
