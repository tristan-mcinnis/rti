import Foundation
import Observation
import RTICore

@Observable @MainActor
final class LLMController {
    private struct ReferencedDocument {
        let path: String
        let content: String
    }

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

    /// Which assistant action ⌘⏎ fires, by `AssistantAction.id`. Remappable per
    /// meeting; persisted. Defaults to "assist". (Was a `PrimaryAction` enum;
    /// the id strings are the same, so the stored value is compatible.)
    var primaryActionID: String {
        didSet { UserDefaults.standard.set(primaryActionID, forKey: Self.primaryActionKey) }
    }

    var recapDepth: RecapDepth {
        didSet { UserDefaults.standard.set(recapDepth.rawValue, forKey: Self.recapDepthKey) }
    }

    /// Passive-listener sessions: the user is observing the meeting, not
    /// speaking. Swaps the moderator-voiced quick actions ("what should I say
    /// next") for observer ones ("what's notable, what could I pass along").
    var listenerMode: Bool {
        didSet { UserDefaults.standard.set(listenerMode, forKey: Self.listenerModeKey) }
    }

    /// Stop listener framing from leaking across sessions. `listenerMode` is a
    /// sticky global, so a fieldwork session leaves it on and the NEXT meeting
    /// then gets the "I'm a passive observer, I never speak" assist prompt —
    /// wrong when the user is actually a participant (the real cause of the
    /// "assist wasn't helpful in the meeting" complaint). At every session start
    /// we keep listener mode ONLY when the active mode is a fieldwork/observation
    /// mode; a normal meeting resets to participant framing.
    func reconcileListenerModeForSessionStart() {
        guard listenerMode else { return }
        let name = (ModeStore.shared.activeMode?.name ?? "").lowercased()
        let fieldwork = ["interview", "observ", "fgd", "idi", "fieldwork", "listen"]
            .contains { name.contains($0) }
        if !fieldwork { listenerMode = false }
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
    private static let recapDepthKey = "rti.llm.recapDepth"
    private static let iso8601 = ISO8601DateFormatter()

    private static let contextWindowSeconds: Double = 900

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
        smartMode = UserDefaults.standard.bool(forKey: Self.smartModeKey)
        primaryActionID = UserDefaults.standard.string(forKey: Self.primaryActionKey) ?? "assist"
        listenerMode = UserDefaults.standard.bool(forKey: Self.listenerModeKey)
        recapDepth = RecapDepth(rawValue: UserDefaults.standard.string(forKey: Self.recapDepthKey) ?? "") ?? .standard
    }

    /// Dispatch the remappable ⌘⏎ action.
    func sendPrimary() {
        perform(actionID: primaryActionID)
    }

    /// Dispatch an assistant action by its `AssistantAction.id`. The single
    /// place mapping an action to its send function — the ✦ menu, command
    /// palette, global hotkeys, and ⌘⏎ all route through here.
    func perform(actionID: String) {
        switch actionID {
        case "assist": sendAssist()
        case "recap": sendRecap()
        case "sayNext": sendSaySomething()
        case "followups": sendFollowupQuestions()
        case "summary": sendSummary()
        case "keyTensions": sendKeyTensions()
        case "probe": sendProbe()
        case "themes": sendThemes()
        default: break
        }
    }

    /// Structured summary of the whole session so far. Shape follows the active
    /// mode (research debrief for interviews, minutes otherwise) and always runs
    /// on the reasoning ("smart") model — the wrap-up is worth the extra latency.
    func sendSummary() {
        let kind = ModeStore.shared.activeMode?.kind ?? .other
        performSend(userInput: PromptStore.shared.summary(for: kind), action: "Summary", fullTranscript: true, forceSmart: true)
    }

    /// Listener research actions — surface tensions / what's unsaid / themes for
    /// a fieldwork observer instead of "what should I say".
    func sendKeyTensions() {
        performSend(userInput: PromptStore.shared.text(.keyTensions), action: "Key tensions")
    }

    func sendProbe() {
        performSend(userInput: PromptStore.shared.text(.probe), action: "Probe")
    }

    func sendThemes() {
        performSend(userInput: PromptStore.shared.text(.themes), action: "Themes")
    }

    func sendAskAnything(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prepared = prepareAskInput(trimmed)
        guard let userInput = prepared.userInput else {
            lastError = prepared.error
            lastErrorIsAuth = false
            return
        }
        performSend(userInput: userInput, action: "Ask", referencedDocuments: prepared.references)
    }

    func sendAssist() {
        performSend(userInput: PromptStore.shared.assist(listener: listenerMode), action: "Assist")
    }

    func sendSaySomething() {
        performSend(userInput: PromptStore.shared.text(.sayNext), action: "Say next")
    }

    func sendFollowupQuestions() {
        performSend(userInput: PromptStore.shared.followups(listener: listenerMode), action: "Follow-ups")
    }

    /// Recap at the given depth, or the user's sticky default when unspecified
    /// (⌘⌥R and the ⌘⏎ primary action both take the default).
    func sendRecap(depth: RecapDepth? = nil) {
        performSend(userInput: PromptStore.shared.recap(depth ?? recapDepth), action: "Recap")
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
        let action = userEntry.action ?? "Ask"
        // performSend re-appends the user turn, so drop it here too.
        entries.removeSubrange(userIdx...)
        // Summary is special: it runs over the FULL transcript on the smart
        // model. The stored user text is the (possibly now-stale) prompt, so
        // re-dispatch through the live summary path rather than replaying it as
        // a normal 15-minute, fast-model turn — otherwise "regenerate" silently
        // produces a different, weaker artifact than the one it's replacing.
        if action == "Summary" {
            sendSummary()
        } else {
            performSend(userInput: userEntry.text, action: action)
        }
    }

    func attachScreenContext(_ text: String) {
        pendingScreenContext = text
        lastError = nil
        lastErrorIsAuth = false
    }

    func clearPendingScreenContext() {
        pendingScreenContext = nil
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

    private func performSend(
        userInput: String,
        action: String,
        fullTranscript: Bool = false,
        forceSmart: Bool = false,
        referencedDocuments: [ReferencedDocument] = []
    ) {
        guard !streaming else { return }
        request.cancel()
        let effectiveSmart = smartMode || forceSmart
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
        // Guide awareness: when a discussion guide is loaded, Assist and
        // Follow-ups see what's still uncovered — "what haven't we asked yet"
        // is the moderator's core anxiety and the listener's best flag.
        if ["Assist", "Follow-ups", "Probe"].contains(action) {
            let coverage = Self.guideCoverageContext()
            if !coverage.isEmpty {
                fullContent += "\n\n\(coverage)"
            }
        }

        let manualScreenContext = pendingScreenContext
        pendingScreenContext = nil
        let manualScreenUsed = manualScreenContext != nil

        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: contextUsed, screenContextUsed: manualScreenUsed))

        let activeMode = ModeStore.shared.activeMode
        let basePrompt: String = {
            if let prompt = activeMode?.systemPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return prompt
            }
            return PromptStore.shared.text(.systemDefault)
        }()
        let effectivePrompt = listenerMode
            ? basePrompt + "\n\n" + PromptStore.shared.text(.listenerSystemSuffix)
            : basePrompt

        // The auto-matched prep brief is for active meeting participation, not
        // passive fieldwork — skip it in listener mode (the brief still loads,
        // it just isn't injected when you're only observing).
        let meetingBrief = listenerMode ? nil : MeetingContextStore.shared.briefContext

        let promptContext = PromptContext(
            baseSystemPrompt: effectivePrompt,
            meetingContext: MeetingContextStore.shared.combined,
            meetingBrief: meetingBrief,
            discussionGuide: DiscussionGuideController.shared.guide?.assistantContextSummary(),
            glossaryFragment: GlossaryStore.shared.systemPromptFragment,
            referenceText: activeMode?.referenceText,
            referenceModeName: activeMode?.name,
            screenContext: manualScreenContext,
            referencedDocuments: referencedDocumentsText(referencedDocuments)
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
            smart: effectiveSmart,
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
            let loop = ToolLoop(request: request)
            await loop.run(
                conversation: apiMessages,
                toolsJSON: toolsJSON,
                smart: effectiveSmart,
                onEvent: { event in
                    MainActor.assumeIsolated {
                        switch event {
                        case let .contentDelta(delta):
                            if self.streamingEntryID != thisEntryID { return }
                            if self.reasoning { self.reasoning = false }
                            self.appendToStreamingEntry(delta)
                        case .reasoningStarted:
                            self.reasoning = true
                        case .reasoningEnded:
                            self.reasoning = false
                        case let .toolStatus(status):
                            self.toolStatus = status
                        case .toolStatusDone:
                            self.toolStatus = nil
                        case let .done(finalText):
                            // Deltas hop to main through a different queue
                            // chain than .done, so the last few can land AFTER
                            // finalize and get dropped — the mid-sentence
                            // truncation bug. .done carries the complete
                            // buffered text; reconcile against it so event
                            // ordering can't lose the tail.
                            if self.streamingEntryID == thisEntryID,
                               let idx = self.entries.firstIndex(where: { $0.id == thisEntryID }),
                               finalText.count > self.entries[idx].text.count
                            {
                                self.entries[idx].text = finalText
                            }
                            self.finalizeAssistantTurn(streamingEntryID: thisEntryID)
                        case let .error(message, isAuth):
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
            transcriptContext: pending.transcriptContext, output: output
        ))
    }

    /// The assistant's previous answers to this same quick action (Assist /
    /// Follow-ups / Say next), newest last, capped to the last 3 so the
    /// anti-repeat context stays small. Recap and free-form Ask are exempt —
    /// repetition is fine there.
    private func priorSuggestions(action: String) -> String {
        guard ["Assist", "Follow-ups", "Say next", "Key tensions", "Probe", "Themes"].contains(action) else { return "" }
        var outputs: [String] = []
        for (idx, entry) in entries.enumerated() {
            guard entry.role == "user", entry.action == action,
                  idx + 1 < entries.count, entries[idx + 1].role == "assistant",
                  !entries[idx + 1].text.isEmpty else { continue }
            outputs.append(entries[idx + 1].text)
        }
        return outputs.suffix(3).map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
    }

    /// Compact "what the discussion guide still needs" block for the
    /// assist-family prompts. Empty string when no guide is loaded or
    /// everything is covered.
    private static func guideCoverageContext() -> String {
        guard let guide = DiscussionGuideController.shared.guide else { return "" }
        var open: [String] = []
        var partial: [String] = []
        for obj in guide.objectives {
            for section in obj.sections {
                for q in section.questions {
                    let line = "[\(section.title)] \(q.text)"
                    switch q.status {
                    case .pending: open.append(line)
                    case .partial: partial.append(line)
                    case .answered: break
                    }
                }
            }
        }
        guard !open.isEmpty || !partial.isEmpty else { return "" }
        var out = "Discussion guide coverage (factor this into your suggestion — flag what's still missing if time is passing):"
        if !open.isEmpty {
            out += "\nNOT yet covered:\n" + open.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        }
        if !partial.isEmpty {
            out += "\nPartially covered:\n" + partial.prefix(6).map { "- \($0)" }.joined(separator: "\n")
        }
        return out
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

    private func prepareAskInput(_ input: String) -> (userInput: String?, references: [ReferencedDocument], error: String?) {
        let mentionResult = Self.extractMentionTokens(from: input)
        guard !mentionResult.tokens.isEmpty else {
            return (input, [], nil)
        }

        var references: [ReferencedDocument] = []
        for token in mentionResult.tokens {
            switch VaultFiles.resolveMention(token, scopeRelativePath: MeetingContextStore.shared.workstreamScopePath) {
            case let .resolved(path, content):
                references.append(ReferencedDocument(path: path, content: content))
            case let .ambiguous(query, candidates):
                let joined = candidates.map { "`\($0)`" }.joined(separator: ", ")
                return (nil, [], "Multiple files match @\(query): \(joined). Use a more specific path.")
            case let .missing(query):
                return (nil, [], "Couldn't find a vault document matching @\(query).")
            }
        }

        let cleaned = mentionResult.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let userInput = cleaned.isEmpty ? "Summarize the referenced document(s)." : cleaned
        return (userInput, references, nil)
    }

    private func referencedDocumentsText(_ documents: [ReferencedDocument]) -> String? {
        guard !documents.isEmpty else { return nil }
        return documents.map { doc in
            "## \(doc.path)\n\n\(doc.content)"
        }.joined(separator: "\n\n")
    }

    private static func extractMentionTokens(from input: String) -> (tokens: [String], cleaned: String) {
        let pattern = #"@"([^"]+)"|@([^\s@]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], input)
        }

        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return ([], input) }

        var tokens: [String] = []
        var cleaned = input
        for match in matches.reversed() {
            let quoted = match.range(at: 1)
            let bare = match.range(at: 2)
            let tokenRange = quoted.location != NSNotFound ? quoted : bare
            if tokenRange.location != NSNotFound {
                tokens.append(ns.substring(with: tokenRange))
            }
            let swiftRange = Range(match.range, in: cleaned)!
            cleaned.removeSubrange(swiftRange)
        }

        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return (tokens.reversed(), cleaned)
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

// MARK: - Mode-aware quick actions

extension LLMController {
    /// The assistant actions to surface in the ✦ menu for the current mode +
    /// listener state — projected from the single `AssistantAction.all`
    /// catalogue (no per-surface registry). The ✦ menu runs each via
    /// `perform(actionID:)`.
    func availableQuickActions() -> [AssistantAction] {
        let kind = ModeStore.shared.activeMode?.kind ?? .other
        let listener = listenerMode
        return AssistantAction.all.filter { action in
            if let lo = action.listenerOnly, lo != listener { return false }
            if let modes = action.modes, !modes.contains(kind) { return false }
            return true
        }
    }

    /// Compact, user-facing description of the context the next assistant turn
    /// can see. Mirrors `performSend` without exposing prompt internals.
    func contextPreviewLabels() -> [String] {
        var labels: [String] = []
        let hasTranscript = SessionCoordinator.shared.liveEntries.contains {
            $0.translationStatus != "translation"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasTranscript { labels.append("Live transcript") }
        if let workstream = MeetingContextStore.shared.workstreamName, !workstream.isEmpty {
            labels.append(workstream)
        }
        if !MeetingContextStore.shared.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append("Meeting note")
        }
        if MeetingContextStore.shared.briefContext != nil {
            labels.append("Brief")
        }
        if DiscussionGuideController.shared.guide != nil {
            labels.append("Guide")
        }
        if !GlossaryStore.shared.entries.isEmpty {
            labels.append("Glossary")
        }
        if pendingScreenContext != nil {
            labels.append("Screen OCR")
        }
        return labels
    }

    func toolPreviewLabels() -> [String] {
        ["Screen", "Vault", "Recent", "Docs", "Grep", "Files"]
    }
}
