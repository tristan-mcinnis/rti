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
            // Skip non-final entries with empty content, but never skip the
            // last user entry — the API needs at least one user message.
            if content.isEmpty, !isLatestUser { continue }
            apiMessages.append(LLMMessage(role: entry.role, content: content))
        }

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        streaming = true
        reasoning = false
        let thisEntryID = assistantEntry.id

        Task { [weak self] in
            await self?.runToolLoop(initialMessages: apiMessages, streamingEntryID: thisEntryID, persistSessionId: persistSessionId)
        }
    }

    /// Runs the streaming chat → execute tools → re-stream loop until the
    /// model produces a stop (or an error / cancel). The streaming
    /// assistant entry's text is appended in-place across iterations so the
    /// user sees one assistant turn even if multiple tools were called.
    private func runToolLoop(initialMessages: [LLMMessage], streamingEntryID thisEntryID: UUID, persistSessionId: String?) async {
        var conversation = initialMessages
        let toolsJSON = LLMToolRegistry.wireFormatData()
        let onReasoning: @Sendable (String) -> Void = { [weak self] _ in
            Task { @MainActor in self?.reasoning = true }
        }

        // Hard cap so a misbehaving model can't loop on tool calls forever.
        let maxIterations = 4
        for _ in 0..<maxIterations {
            // Track this turn's content so we can append it to the wire
            // history if the model also emits tool_calls (assistant message
            // with both content + tool_calls is permitted).
            let turnContent = TurnContentBuffer()

            let onContent: @Sendable (String) -> Void = { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.reasoning { self.reasoning = false }
                    if self.streamingEntryID != thisEntryID { return }
                    self.appendToStreamingEntry(delta)
                    turnContent.append(delta)
                }
            }

            let result: LLMClient.ToolAwareStreamResult
            do {
                result = try await request.streamWithTools(
                    messages: conversation,
                    toolsJSON: toolsJSON,
                    smart: smartMode,
                    onContent: onContent,
                    onReasoning: onReasoning
                )
            } catch is CancellationError {
                return
            } catch {
                guard streamingEntryID == thisEntryID else { return }
                let llmError = error as? LLMError
                lastError = llmError?.userMessage ?? "\(error)"
                lastErrorIsAuth = llmError?.isAuth ?? false
                streaming = false
                reasoning = false
                toolStatus = nil
                pruneTrailingEmptyAssistant()
                streamingEntryID = nil
                NSLog("[RTI] LLM stream error: \(lastError ?? "unknown")")
                RTILog.log("stream error: \(lastError ?? "unknown")", category: "llm")
                return
            }

            // No tools requested → this is the terminal turn. Persist + done.
            guard !result.toolCalls.isEmpty else {
                finalizeAssistantTurn(streamingEntryID: thisEntryID, persistSessionId: persistSessionId)
                return
            }

            // Append the assistant's tool_call message to the wire history,
            // then run each tool and append a `tool` message with its result.
            conversation.append(LLMMessage(
                role: "assistant",
                content: turnContent.snapshot().nilIfEmpty,
                tool_calls: result.toolCalls
            ))

            for call in result.toolCalls {
                let resultText = await executeTool(call)
                conversation.append(LLMMessage(
                    role: "tool",
                    content: resultText,
                    tool_call_id: call.id,
                    name: call.function.name
                ))
            }
            // Loop back: model now sees its tool results and continues.
        }

        // Hit the iteration cap — finalize what we have so the user isn't
        // left with a half-streamed bubble.
        finalizeAssistantTurn(streamingEntryID: thisEntryID, persistSessionId: persistSessionId)
    }

    /// Locates the requested tool, runs it, and returns either its output
    /// or an error string the model can read. Updates `toolStatus` so the
    /// UI can show what's happening while the tool is running.
    private func executeTool(_ call: LLMToolCall) async -> String {
        guard let tool = LLMToolRegistry.tool(named: call.function.name) else {
            return "Tool '\(call.function.name)' is not available."
        }
        toolStatus = tool.runningStatus ?? "Running \(tool.name)…"
        defer { toolStatus = nil }
        do {
            let output = try await tool.execute(call.function.arguments)
            NSLog("[RTI] Tool '\(tool.name)' produced \(output.count) chars")
            return output
        } catch {
            let msg = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
            NSLog("[RTI] \(msg)")
            return msg
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

/// Tiny actor-isolated string buffer used by the tool loop to capture this
/// turn's emitted content (so we can re-attach it to the wire history if the
/// model also requested a tool call). Kept as a class rather than a value
/// type so the @Sendable onContent closure can mutate shared state safely.
private final class TurnContentBuffer: @unchecked Sendable {
    private var text: String = ""
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return text }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
