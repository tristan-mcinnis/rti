import Foundation
import Observation
import RTICore

@Observable @MainActor
final class LLMController {
    static let shared = LLMController()

    private(set) var entries: [ChatEntry] = []
    private(set) var streaming = false
    private(set) var reasoning = false
    private(set) var lastError: String?
    private(set) var lastErrorIsAuth: Bool = false
    private(set) var pendingScreenContext: String?
    /// Human-readable status shown beneath the streaming assistant entry
    /// while a tool is running (e.g. "📷 Looking at your screen…"). Nil
    /// when idle or when only content tokens are streaming.
    private(set) var toolStatus: String?
    var smartMode: Bool {
        didSet { UserDefaults.standard.set(smartMode, forKey: Self.smartModeKey) }
    }

    /// Which quick action ⌘⏎ fires. Remappable per meeting (e.g. Recap when
    /// you're a passive listener and never need Assist).
    enum PrimaryAction: String, CaseIterable {
        case assist, recap, sayNext, followups, summary

        var label: String {
            switch self {
            case .assist: return "Assist"
            case .recap: return "Recap"
            case .sayNext: return "Say Next"
            case .followups: return "Follow-ups"
            case .summary: return "Summary"
            }
        }
    }

    var primaryAction: PrimaryAction {
        didSet { UserDefaults.standard.set(primaryAction.rawValue, forKey: Self.primaryActionKey) }
    }

    /// Passive-listener sessions: the user is observing the meeting, not
    /// speaking. Swaps the moderator-voiced quick actions ("what should I say
    /// next") for observer ones ("what's notable, what could I pass along").
    var listenerMode: Bool {
        didSet { UserDefaults.standard.set(listenerMode, forKey: Self.listenerModeKey) }
    }

    private let request: LLMRequest
    private var streamingEntryID: UUID?
    /// Metadata for the in-flight turn, written to the vault turn log on
    /// successful completion (see VaultLogStore).
    private var pendingTurn: PendingTurn?

    private struct PendingTurn {
        let id: UUID
        let ts: String
        let action: String
        let mode: String?
        let provider: String
        let model: String
        let smart: Bool
        let inSession: Bool
        let contextUsed: Bool
        let screenUsed: Bool
        let userInput: String
        let transcriptContext: String
    }

    private static let smartModeKey = "rti.llm.smartMode"
    private static let primaryActionKey = "rti.llm.primaryAction"
    private static let listenerModeKey = "rti.llm.listenerMode"
    private static let iso8601 = ISO8601DateFormatter()

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

    /// Granola-style whole-meeting summary — runs over the FULL transcript,
    /// not the 15-minute assist window. Internal: SessionArchive reuses it
    /// for the end-of-session auto-summary so chat and archive stay identical.
    static let meetingSummaryPrompt = """
    Write a structured summary of this ENTIRE meeting so far, in markdown. Work \
    only from what was actually said — no invention, no padding.

    ## TL;DR
    2–3 sentences: what this meeting was, what it covered, the single most \
    important takeaway.

    ## Key points
    The substantive content, grouped under short bold topic headers in the order \
    the topics arose. Concrete and specific — keep names, brands, numbers, and \
    essential original-language terms in parentheses (e.g. 松弛, 背刺). Attribute \
    views to named people where clear, otherwise by role.

    ## Decisions & agreements
    Anything decided, agreed, or confirmed. If none, write "None."

    ## Tensions & contradictions
    Where views split, or someone contradicted themselves or the group. These \
    are often the most valuable — be precise about who held which side. If \
    none, write "None observed."

    ## Open questions & follow-ups
    Unresolved threads, things someone said they'd do, topics raised but not \
    explored.

    Rules: write in English (translate as needed); skip greetings, logistics, \
    and side conversations about tools or scheduling; never use raw transcript \
    labels like "them_1".
    """

    // Listener-mode variants: the user is observing, not speaking, so "what
    // should I say" is the wrong frame. Surface what's notable instead.
    private static let listenerAssistPrompt = "I'm a passive listener in this meeting, not a speaker. In max 3 short lines: flag the most notable thing in the recent conversation (an insight, contradiction, or thread the group is missing) and why it matters."
    private static let listenerFollowupsPrompt = "I'm a passive listener. List 3 sharp questions the discussion leader could ask right now to deepen the conversation — questions I could quietly pass along. Bullet points, one line each."

    private static let contextWindowSeconds: Double = 900

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
        self.smartMode = UserDefaults.standard.bool(forKey: Self.smartModeKey)
        self.primaryAction = PrimaryAction(rawValue: UserDefaults.standard.string(forKey: Self.primaryActionKey) ?? "") ?? .assist
        self.listenerMode = UserDefaults.standard.bool(forKey: Self.listenerModeKey)
    }

    /// Dispatch the remappable ⌘⏎ action.
    func sendPrimary() {
        switch primaryAction {
        case .assist: sendAssist()
        case .recap: sendRecap()
        case .sayNext: sendSaySomething()
        case .followups: sendFollowupQuestions()
        case .summary: sendSummary()
        }
    }

    /// Granola-style structured summary of the whole meeting so far.
    func sendSummary() {
        performSend(userInput: Self.meetingSummaryPrompt, action: "Summary", fullTranscript: true)
    }

    func sendAskAnything(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSend(userInput: trimmed, action: "Ask")
    }

    func sendAssist() {
        performSend(userInput: listenerMode ? Self.listenerAssistPrompt : Self.assistPrompt, action: "Assist")
    }

    func sendSaySomething() {
        performSend(userInput: Self.saySomethingPrompt, action: "Say next")
    }

    func sendFollowupQuestions() {
        performSend(userInput: listenerMode ? Self.listenerFollowupsPrompt : Self.followupsPrompt, action: "Follow-ups")
    }

    func sendRecap() {
        performSend(userInput: Self.recapPrompt, action: "Recap")
    }

    /// Re-run the turn that produced `assistantID`: drop that assistant reply
    /// (and anything after it), then re-send the user turn it answered.
    /// Transcript context is rebuilt fresh from the current live entries.
    func regenerate(assistantID: UUID) {
        guard !streaming,
              let assistantIdx = entries.firstIndex(where: { $0.id == assistantID }),
              entries[assistantIdx].role == "assistant" else { return }
        let userIdx = assistantIdx - 1
        guard userIdx >= 0, entries[userIdx].role == "user" else { return }
        let userEntry = entries[userIdx]
        // performSend re-appends the user turn, so drop it here too.
        entries.removeSubrange(userIdx...)
        performSend(userInput: userEntry.text, action: userEntry.action ?? "Ask")
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
        pendingTurn = nil
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages.
    func resetMemory() {
        cancel()
        entries = []
        lastError = nil
        lastErrorIsAuth = false
    }

    /// Clear the in-memory chat. Ephemeral build: there's no persisted history.
    func clear() {
        resetMemory()
    }

    private func performSend(userInput: String, action: String, fullTranscript: Bool = false) {
        request.cancel()
        lastError = nil
        lastErrorIsAuth = false
        toolStatus = nil

        let transcript = recentTranscriptText(fullWindow: fullTranscript)
        let contextUsed = !transcript.isEmpty
        // Quick actions fire repeatedly during a session; without memory of
        // its own prior output the model re-suggests the same thing every
        // time. Feed back what it already said and ask it to move on.
        let priorBlock = priorSuggestions(action: action)
        let contextLabel = fullTranscript
            ? "Full meeting transcript (diarized)"
            : "Recent conversation (last 15 minutes, diarized)"
        var fullContent = contextUsed
            ? "\(contextLabel):\n\(transcript)\n\nUser question: \(userInput)"
            : userInput
        if !priorBlock.isEmpty {
            fullContent += "\n\nYou already suggested the following earlier in this session — do NOT repeat or rephrase these; build on the newest conversation instead:\n\(priorBlock)"
        }

        let manualScreenContext = pendingScreenContext
        pendingScreenContext = nil
        let manualScreenUsed = manualScreenContext != nil

        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: contextUsed, screenContextUsed: manualScreenUsed))

        let activeMode = ModeStore.shared.activeMode
        let basePrompt: String = {
            if let prompt = activeMode?.systemPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return prompt
            }
            return Self.systemPrompt
        }()
        let effectivePrompt = listenerMode
            ? basePrompt + "\n\nThe user is a PASSIVE LISTENER in this meeting — observing, not speaking. Never draft lines for them to say; frame help as observations, flags, and questions they could pass to whoever is leading."
            : basePrompt

        let promptContext = PromptContext(
            baseSystemPrompt: effectivePrompt,
            meetingContext: MeetingContextStore.shared.combined,
            glossaryFragment: GlossaryStore.shared.systemPromptFragment,
            referenceText: activeMode?.referenceText,
            referenceModeName: activeMode?.name,
            screenContext: manualScreenContext
        )

        var apiMessages = PromptBuilder.buildSystemMessages(context: promptContext)
        apiMessages.append(contentsOf: PromptBuilder.buildConversationMessages(entries: entries, fullContent: fullContent))

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        pendingTurn = PendingTurn(
            id: assistantEntry.id,
            ts: Self.iso8601.string(from: Date()),
            action: action,
            mode: activeMode?.name,
            provider: LLMProviders.activeId,
            model: LLMProviders.active.model,
            smart: smartMode,
            inSession: SessionCoordinator.shared.isRunning,
            contextUsed: contextUsed,
            screenUsed: manualScreenUsed,
            userInput: userInput,
            transcriptContext: transcript
        )

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
                            self.finalizeAssistantTurn(streamingEntryID: thisEntryID)
                        case .error(let message, let isAuth):
                            guard self.streamingEntryID == thisEntryID else { return }
                            self.lastError = message
                            self.lastErrorIsAuth = isAuth
                            self.streaming = false
                            self.reasoning = false
                            self.toolStatus = nil
                            self.pruneTrailingEmptyAssistant()
                            self.streamingEntryID = nil
                            self.pendingTurn = nil
                            RTILog.log("LLM stream error: \(message)", category: "llm")
                        }
                    }
                }
            )
        }
    }

    private func finalizeAssistantTurn(streamingEntryID thisEntryID: UUID) {
        guard streamingEntryID == thisEntryID else { return }
        streaming = false
        reasoning = false
        toolStatus = nil
        logCompletedTurn(thisEntryID)
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
    }

    /// Write the just-finished turn (prompt metadata + output) to the vault
    /// turn log. Skips empty/cancelled turns. Captures standalone chats too.
    private func logCompletedTurn(_ id: UUID) {
        guard let pending = pendingTurn, pending.id == id,
              let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        pendingTurn = nil
        let output = entries[idx].text
        guard !output.isEmpty else { return }
        VaultLogStore.append(.init(
            ts: pending.ts, action: pending.action, mode: pending.mode,
            provider: pending.provider, model: pending.model, smart: pending.smart,
            inSession: pending.inSession, contextUsed: pending.contextUsed,
            screenUsed: pending.screenUsed, userInput: pending.userInput,
            transcriptContext: pending.transcriptContext, output: output))
    }

    /// The assistant's previous answers to this same quick action (Assist /
    /// Follow-ups / Say next), newest last, capped to the last 3 so the
    /// anti-repeat context stays small. Recap and free-form Ask are exempt —
    /// repetition is fine there.
    private func priorSuggestions(action: String) -> String {
        guard ["Assist", "Follow-ups", "Say next"].contains(action) else { return "" }
        var outputs: [String] = []
        for (idx, entry) in entries.enumerated() {
            guard entry.role == "user", entry.action == action,
                  idx + 1 < entries.count, entries[idx + 1].role == "assistant",
                  !entries[idx + 1].text.isEmpty else { continue }
            outputs.append(entries[idx + 1].text)
        }
        return outputs.suffix(3).map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
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

    /// Build the recent diarized transcript from the in-memory live entries,
    /// limited to the trailing context window. Ephemeral build: there's no
    /// on-disk transcript to read — the live entries are the only source.
    ///
    /// When the window contains user-typed notes, they are hoisted into a
    /// "## User notes" preamble at the top — matching the contract described
    /// in the system prompt above.
    private func recentTranscriptText(fullWindow: Bool = false) -> String {
        // Exclude live-translation tokens — the assistant reads the original
        // spoken transcript, not its translated duplicate.
        let all = SessionCoordinator.shared.liveEntries.filter { $0.translationStatus != "translation" }
        guard !all.isEmpty else { return "" }
        let maxMs = all.map(\.startMs).max() ?? 0
        let windowMs = Int(Self.contextWindowSeconds * 1000)
        let threshold = fullWindow ? 0 : max(0, maxMs - windowMs)
        let windowed = all.filter { $0.startMs >= threshold }

        // Stable appearance-ordered speaker numbers (from the full session,
        // not the window) so the assistant can tell participants apart and
        // attribute consistently across turns.
        var speakerNumber: [String: Int] = [:]
        var nextNumber = 1
        for e in all where e.speakerId != "self" && e.speakerId != "note" {
            if speakerNumber[e.speakerId] == nil {
                speakerNumber[e.speakerId] = nextNumber
                nextNumber += 1
            }
        }
        let formatLine: (LiveEntry) -> String = { entry in
            switch entry.speakerId {
            case "self": return "Me: \(entry.text)"
            case "note": return "[my note]: \(entry.text)"
            default:
                let n = speakerNumber[entry.speakerId].map { "Speaker \($0)" } ?? "Speaker ?"
                return "\(n): \(entry.text)"
            }
        }
        let inline = windowed.map(formatLine).joined(separator: "\n")

        let notes = windowed.filter { $0.speakerId == "note" }
        guard !notes.isEmpty else { return inline }
        let header = "## User notes (authoritative — trust these over any transcript ambiguity)"
        let bullets = notes.map { "- \($0.text)" }.joined(separator: "\n")
        return "\(header)\n\(bullets)\n\n\(inline)"
    }
}
