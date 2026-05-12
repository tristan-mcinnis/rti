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
    /// Human-readable status shown beneath the streaming assistant entry
    /// while a tool is running (e.g. "📷 Looking at your screen…"). Nil
    /// when idle or when only content tokens are streaming.
    @Published private(set) var toolStatus: String?
    @Published var smartMode: Bool {
        didSet { UserDefaults.standard.set(smartMode, forKey: Self.smartModeKey) }
    }

    private let request: LLMRequest
    private var streamingEntryID: UUID?

    private static let smartModeKey = "rti.llm.smartMode"

    private static let systemPrompt = """
    You are RTI, a real-time meeting assistant. The user is in an active conversation.
    Keep responses short (under 120 words), direct, and actionable. Use simple markdown
    where it helps (bullets, **bold** for key terms). If you don't know something, say so briefly.

    If the transcript context starts with a "## User notes" block, treat those notes as
    authoritative corrections from the user (e.g. name spellings, identity clarifications).
    Prefer them over what appears in the raw transcript.
    """

    private static let assistPrompt = "Based on the recent conversation, suggest what I should say or ask next. Be concise — max 3 short lines."
    private static let saySomethingPrompt = "Given the conversation so far, draft exactly one short reply I could say next. One line, natural, in my voice. No preamble."
    private static let followupsPrompt = "List 3 thoughtful follow-up questions I could ask the other person right now. Bullet points, one line each."
    private static let recapPrompt = "Recap the conversation so far in 3–5 short bullets: what was discussed, decisions, open items."

    private static let contextWindowSeconds: Double = 360

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
        self.smartMode = UserDefaults.standard.bool(forKey: Self.smartModeKey)
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
        request.cancel()
        streaming = false
        reasoning = false
        toolStatus = nil
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages.
    func resetMemory() {
        cancel()
        entries = []
        lastError = nil
        lastErrorIsAuth = false
    }

    /// Destructive: in-memory reset PLUS deletion of chat_messages for the
    /// current session.
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
        request.cancel()
        lastError = nil
        lastErrorIsAuth = false
        toolStatus = nil

        let transcript = recentTranscriptText()
        let contextUsed = !transcript.isEmpty
        let fullContent = contextUsed
            ? "Recent conversation (last 6 minutes, diarized):\n\(transcript)\n\nUser question: \(userInput)"
            : userInput

        let manualScreenContext = pendingScreenContext
        pendingScreenContext = nil
        let manualScreenUsed = manualScreenContext != nil

        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: contextUsed, screenContextUsed: manualScreenUsed))

        let persistSessionId = SessionCoordinator.shared.currentSessionId
        if let persistSessionId {
            persistMessage(sessionId: persistSessionId, role: "user", action: action, content: userInput, hadTranscript: contextUsed, hadScreen: manualScreenUsed)
        }

        let activeMode = ModeStore.shared.activeMode
        let basePrompt: String = {
            if let prompt = activeMode?.systemPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prompt
            }
            return Self.systemPrompt
        }()

        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: basePrompt)]
        if let glossary = GlossaryStore.shared.systemPromptFragment {
            apiMessages.append(LLMMessage(role: "system", content: glossary))
        }
        if let reference = activeMode?.referenceText, !reference.isEmpty {
            let capped = reference.count > 8000 ? String(reference.prefix(8000)) + "\n…[truncated]" : reference
            let modeName = activeMode?.name ?? "active mode"
            apiMessages.append(LLMMessage(
                role: "system",
                content: "Reference material attached to the active mode '\(modeName)'. Use it when relevant.\n---\n\(capped)\n---"
            ))
        }
        if let manualScreenContext {
            apiMessages.append(LLMMessage(
                role: "system",
                content: "User attached a screenshot. OCR text from the screen follows. Treat it as what the user is looking at.\n---\n\(manualScreenContext)\n---"
            ))
        }
        for (idx, entry) in entries.enumerated() {
            let isLatestUser = idx == entries.count - 1 && entry.role == "user"
            let content = isLatestUser ? fullContent : entry.text
            if content.isEmpty, !isLatestUser { continue }
            apiMessages.append(LLMMessage(role: entry.role, content: content))
        }

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        streaming = true
        reasoning = false
        let thisEntryID = assistantEntry.id

        let toolsJSON = LLMToolRegistry.wireFormatData()

        Task { [weak self] in
            guard let self else { return }
            let loop = ToolLoop(request: self.request)
            await loop.run(
                conversation: apiMessages,
                toolsJSON: toolsJSON,
                smart: self.smartMode,
                onEvent: { event in
                    MainActor.assumeIsolated {
                        switch event {
                        case .contentDelta(let delta):
                            if self.streamingEntryID != thisEntryID { return }
                            if self.reasoning { self.reasoning = false }
                            self.appendToStreamingEntry(delta)
                        case .reasoningStarted:
                            self.reasoning = true
                        case .reasoningEnded:
                            self.reasoning = false
                        case .toolStatus(let status):
                            self.toolStatus = status
                        case .toolStatusDone:
                            self.toolStatus = nil
                        case .done:
                            self.finalizeAssistantTurn(streamingEntryID: thisEntryID, persistSessionId: persistSessionId)
                        case .error(let message, let isAuth):
                            guard self.streamingEntryID == thisEntryID else { return }
                            self.lastError = message
                            self.lastErrorIsAuth = isAuth
                            self.streaming = false
                            self.reasoning = false
                            self.toolStatus = nil
                            self.pruneTrailingEmptyAssistant()
                            self.streamingEntryID = nil
                            NSLog("[RTI] LLM stream error: \(message)")
                            RTILog.log("stream error: \(message)", category: "llm")
                        }
                    }
                }
            )
        }
    }

    private func finalizeAssistantTurn(streamingEntryID thisEntryID: UUID, persistSessionId: String?) {
        guard streamingEntryID == thisEntryID else { return }
        streaming = false
        reasoning = false
        toolStatus = nil
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil

        let finalSessionId = SessionCoordinator.shared.currentSessionId ?? persistSessionId
        if let finalSessionId,
           let finalText = entries.last(where: { $0.id == thisEntryID })?.text,
           !finalText.isEmpty {
            persistMessage(sessionId: finalSessionId, role: "assistant", action: nil, content: finalText, hadTranscript: false, hadScreen: false)
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
        return TranscriptContext.text(forSessionId: sessionId, sinceMs: threshold)
    }
}