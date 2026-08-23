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
    private(set) var screenCaptureStatus: String?
    private(set) var toolTraces: [UUID: String] = [:]
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
    /// Modes were removed; RTI only has the one built-in Meeting persona, so
    /// there is no automatic fieldwork detection any more — listener mode is
    /// purely a manual toggle now.
    func reconcileListenerModeForSessionStart() {}

    private let request: LLMRequest
    private var streamingEntryID: UUID?
    private var activeToolTraceLines: [String] = []
    /// Metadata for the in-flight turn, written to the vault turn log on
    /// successful completion (see VaultLogStore).
    private var pendingTurn: PendingTurn?

    private struct PendingTurn {
        let id: UUID
        let ts: String
        let startedAt: Date
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
        var firstTokenAt: Date?
        var toolElapsedMS: Int
        var toolCount: Int
        var sources: [String]
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
        primaryActionID = UserDefaults.standard.string(forKey: Self.primaryActionKey) ?? "answerLatest"
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
        case "answerLatest": sendAnswerLatest()
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
        performSend(userInput: PromptStore.shared.summary(for: .meeting), action: "Summary", fullTranscript: true, forceSmart: true)
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
        guard !streaming else { return }
        // An explicit attachment/@mention is the user's chosen source; the
        // vault RAG search that used to run otherwise was removed with the
        // tool loop, so a plain "Ask" now just answers from the live
        // transcript + any @mentioned document.
        if !prepared.references.isEmpty {
            let label = prepared.references.count == 1
                ? "Attached source"
                : "\(prepared.references.count) attached sources"
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                initialTrace: label
            )
            return
        }
        performSend(userInput: userInput, action: "Ask")
    }

    func sendAssist() {
        performSend(userInput: PromptStore.shared.assist(listener: listenerMode), action: "Assist")
    }

    func sendAnswerLatest() {
        guard !streaming else { return }
        let window = recentTranscriptText(maxSeconds: 180)
        guard !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "No live transcript yet."
            lastErrorIsAuth = false
            return
        }
        let prompt = """
        Answer the MOST recent client question, challenge, or decision point in the live transcript.
        If the latest point is answerable from the current transcript, answer directly from that.
        Be concise and practical: what should I say now, or what answer should I give?
        Do not narrate the search process. Do not say "let me search" or "I found". Return only the final answer.
        """
        performSend(userInput: prompt, action: "Answer latest")
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
        } else if action == "Ask" {
            // Re-run the deterministic vault search rather than replay through
            // bare performSend, which skipped retrieval entirely and answered
            // from the transcript/priors alone.
            sendAskAnything(userEntry.text)
        } else {
            performSend(userInput: userEntry.text, action: action)
        }
    }

    func attachScreenContext(_ text: String) {
        pendingScreenContext = text
        screenCaptureStatus = nil
        lastError = nil
        lastErrorIsAuth = false
    }

    func clearPendingScreenContext() {
        pendingScreenContext = nil
        screenCaptureStatus = nil
    }

    func setScreenAttachError(_ message: String) {
        screenCaptureStatus = message
        lastError = message
        lastErrorIsAuth = false
    }

    func setScreenCaptureStatus(_ message: String?) {
        screenCaptureStatus = message
    }

    func cancel() {
        request.cancel()
        streaming = false
        reasoning = false
        toolStatus = nil
        activeToolTraceLines = []
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
        pendingTurn = nil
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages.
    func resetMemory() {
        cancel()
        entries = []
        toolTraces = [:]
        lastError = nil
        lastErrorIsAuth = false
    }

    /// Clear the in-memory chat. Ephemeral build: there's no persisted history.
    func clear() {
        resetMemory()
    }

    func showSlashHelp() {
        postLocalTurn(
            userInput: "/help",
            action: "Help",
            output: """
            **Slash commands**
            `/project [name]` — set project/client context by name. Blank shows current context. Use `/project clear` to go vault-wide.
            `/answer` — answer the latest live question/point.
            `/recent` — ask about recent sessions for the selected project.
            `/note <text>` — add a live transcript note.
            `/new` — clear this chat.

            `@file-or-phrase` attaches a vault document by path.
            """
        )
    }

    func runProjectCommand(_ argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let current = MeetingContextStore.shared.workstreamName.map { "Current context: **\($0)**" }
                ?? "No project/client selected. RAG defaults to the whole vault."
            let projects = VaultWorkstreamStore.projects().prefix(8).map(\.name).joined(separator: ", ")
            let clients = VaultWorkstreamStore.clients().prefix(5).map(\.name).joined(separator: ", ")
            let examples = "Use `/project acme brand`, `/project clear`, or pick one in Setup."
            postLocalTurn(
                userInput: "/project",
                action: "Project",
                output: "\(current)\n\nProjects: \(projects.isEmpty ? "none found" : projects)\n\nClients: \(clients.isEmpty ? "none found" : clients)\n\n\(examples)"
            )
            return
        }
        if ["clear", "none", "vault", "all"].contains(trimmed.lowercased()) {
            MeetingContextStore.shared.clearWorkstream()
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "Project/client context cleared. Vault commands and RAG now search the whole vault by default.")
            return
        }
        if let item = MeetingContextStore.shared.selectWorkstream(matching: trimmed) {
            let kind = item.isProject ? "project" : "client"
            let scope = item.isProject ? (VaultWorkstreamStore.scopeRelativePath(for: item) ?? "unknown") : (VaultWorkstreamStore.fileAccessRelativePath(for: item) ?? "unknown")
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "Using \(kind): **\(item.name)**\n\nScope: `\(scope)`")
        } else {
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "No matching project or client found for `\(trimmed)`. Try a shorter name or pick it in Setup.")
        }
    }

    private func performSend(
        userInput: String,
        action: String,
        fullTranscript: Bool = false,
        forceSmart: Bool = false,
        referencedDocuments: [ReferencedDocument] = [],
        retrievalContext: String? = nil,
        initialTrace: String? = nil
    ) {
        guard !streaming else { return }
        request.cancel()
        let effectiveSmart = smartMode || forceSmart
        lastError = nil
        lastErrorIsAuth = false
        toolStatus = nil

        let transcript = recentTranscriptText(fullWindow: fullTranscript)
        let manualScreenContext = pendingScreenContext
        pendingScreenContext = nil
        let screenContext = [manualScreenContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
        let screenUsed = !screenContext.isEmpty

        // Modes were removed — RTI always runs the one built-in Meeting
        // system prompt.
        let basePrompt = PromptStore.shared.text(.systemDefault)

        let turn = AssistantTurnBuilder.build(.init(
            userInput: userInput,
            action: action,
            transcript: transcript,
            fullTranscript: fullTranscript,
            workstreamScopePath: MeetingContextStore.shared.workstreamScopePath,
            hasWorkstreamName: MeetingContextStore.shared.workstreamName != nil,
            priorSuggestions: priorSuggestions(action: action),
            hasReferencedDocuments: !referencedDocuments.isEmpty,
            retrievalContext: retrievalContext,
            guideCoverage: Self.guideCoverageContext(),
            baseSystemPrompt: basePrompt,
            listenerSystemSuffix: PromptStore.shared.text(.listenerSystemSuffix),
            listenerMode: listenerMode,
            meetingContext: MeetingContextStore.shared.combined,
            meetingBrief: nil,
            discussionGuide: nil,
            glossaryFragment: nil,
            referenceText: nil,
            referenceModeName: nil,
            screenContext: screenUsed ? screenContext : nil,
            referencedDocumentsText: referencedDocumentsText(referencedDocuments),
            existingEntries: entries
        ))

        entries.append(ChatEntry(
            role: "user",
            text: userInput,
            action: action,
            contextUsed: turn.contextUsed,
            screenContextUsed: screenUsed,
            referencedPaths: referencedDocuments.map(\.path)
        ))

        let apiMessages = turn.apiMessages

        let assistantEntry = ChatEntry(role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false)
        streamingEntryID = assistantEntry.id
        activeToolTraceLines = []
        entries.append(assistantEntry)
        if let initialTrace, !initialTrace.isEmpty {
            toolTraces[assistantEntry.id] = initialTrace
        }

        pendingTurn = PendingTurn(
            id: assistantEntry.id,
            ts: Self.iso8601.string(from: Date()),
            startedAt: Date(),
            action: action,
            mode: nil,
            provider: LLMProviders.activeId,
            model: LLMProviders.active.model,
            smart: effectiveSmart,
            inSession: SessionCoordinator.shared.isRunning,
            contextUsed: turn.contextUsed,
            screenUsed: screenUsed,
            userInput: userInput,
            transcriptContext: transcript,
            firstTokenAt: nil,
            toolElapsedMS: 0,
            toolCount: 0,
            sources: initialTrace.map(sourcePaths(in:)) ?? []
        )

        streaming = true
        reasoning = false
        let thisEntryID = assistantEntry.id

        // The tool loop (vault search / read / grep / list tools) was
        // removed with the vault-search strip — this is now a single
        // streaming completion with no function calling.
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.request.streamWithTools(
                    messages: apiMessages,
                    toolsJSON: nil,
                    smart: effectiveSmart,
                    onContent: { delta in
                        Task { @MainActor in
                            guard self.streamingEntryID == thisEntryID else { return }
                            if self.reasoning { self.reasoning = false }
                            self.markFirstTokenIfNeeded()
                            self.appendToStreamingEntry(delta)
                        }
                    },
                    onReasoning: { _ in
                        Task { @MainActor in self.reasoning = true }
                    }
                )
                self.finalizeAssistantTurn(streamingEntryID: thisEntryID)
            } catch is CancellationError {
                return
            } catch {
                guard self.streamingEntryID == thisEntryID else { return }
                let llmError = error as? LLMError
                self.lastError = llmError?.userMessage ?? "\(error)"
                self.lastErrorIsAuth = llmError?.isAuth ?? false
                self.streaming = false
                self.reasoning = false
                self.toolStatus = nil
                self.activeToolTraceLines = []
                self.pruneTrailingEmptyAssistant()
                self.streamingEntryID = nil
                self.pendingTurn = nil
                RTILog.log("LLM stream error: \(error)", category: "llm")
            }
        }
    }

    private func finalizeAssistantTurn(streamingEntryID thisEntryID: UUID) {
        guard streamingEntryID == thisEntryID else { return }
        streaming = false
        reasoning = false
        toolStatus = nil
        activeToolTraceLines = []
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
        let totalMS = Int(Date().timeIntervalSince(pending.startedAt) * 1000)
        let firstTokenMS = pending.firstTokenAt.map { Int($0.timeIntervalSince(pending.startedAt) * 1000) }
        RTILog.log(
            "turn \(pending.action) total=\(totalMS)ms firstToken=\(firstTokenMS.map(String.init) ?? "n/a")ms tools=\(pending.toolCount) toolMs=\(pending.toolElapsedMS) sources=\(pending.sources.count)",
            category: "latency"
        )
        VaultLogStore.append(.init(
            ts: pending.ts, action: pending.action, mode: pending.mode,
            provider: pending.provider, model: pending.model, smart: pending.smart,
            inSession: pending.inSession, contextUsed: pending.contextUsed,
            screenUsed: pending.screenUsed, userInput: pending.userInput,
            transcriptContext: pending.transcriptContext, output: output,
            latency: .init(
                totalMs: totalMS,
                firstTokenMs: firstTokenMS,
                toolMs: pending.toolElapsedMS,
                toolCount: pending.toolCount
            ),
            sources: pending.sources
        ))
    }

    private func markFirstTokenIfNeeded() {
        guard pendingTurn?.firstTokenAt == nil else { return }
        pendingTurn?.firstTokenAt = Date()
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

    /// Discussion-guide coverage is unavailable — the real-time analysis
    /// engine was removed. Kept as a no-op so prompt assembly doesn't need
    /// restructuring.
    private static func guideCoverageContext() -> String { "" }

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
        var references: [ReferencedDocument] = []
        for token in mentionResult.tokens {
            switch VaultFiles.resolveMention(token, scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath) {
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

    private func postLocalTurn(userInput: String, action: String, output: String) {
        guard !streaming else { return }
        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: false, screenContextUsed: false))
        entries.append(ChatEntry(role: "assistant", text: output, action: nil, contextUsed: false, screenContextUsed: false))
    }

    private func updateLocalAssistant(_ id: UUID, text: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
    }

    private func beginLocalProgress(userInput: String, action: String, text: String) -> UUID {
        lastError = nil
        lastErrorIsAuth = false
        streaming = true
        toolStatus = nil
        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: false, screenContextUsed: false))
        let assistant = ChatEntry(role: "assistant", text: text, action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(assistant)
        streamingEntryID = assistant.id
        return assistant.id
    }

    private func removeLocalProgress(_ assistantID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == assistantID }) else {
            streaming = false
            streamingEntryID = nil
            return
        }
        let userIdx = idx > 0 && entries[idx - 1].role == "user" ? idx - 1 : idx
        entries.removeSubrange(userIdx...idx)
        toolTraces[assistantID] = nil
        streaming = false
        streamingEntryID = nil
        toolStatus = nil
    }

    func toolTrace(for id: UUID) -> String? {
        toolTraces[id]
    }

    private func sourcePaths(in text: String) -> [String] {
        let pattern = #"\(([^(),]+\.md), updated \d{4}-\d{2}-\d{2}\)|\(([^(),]+\.md)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for idx in 1..<match.numberOfRanges where match.range(at: idx).location != NSNotFound {
                let path = ns.substring(with: match.range(at: idx))
                if !out.contains(path) { out.append(path) }
            }
        }
        return out
    }

    /// Build the recent diarized transcript from the in-memory live entries,
    /// limited to the trailing context window. Ephemeral build: there's no
    /// on-disk transcript to read — the live entries are the only source.
    ///
    /// When the window contains user-typed notes, they are hoisted into a
    /// "## User notes" preamble at the top — matching the contract described
    /// in the system prompt above.
    private func recentTranscriptText(fullWindow: Bool = false, maxSeconds: Double? = nil) -> String {
        // Exclude live-translation tokens — the assistant reads the original
        // spoken transcript, not its translated duplicate.
        let all = SessionCoordinator.shared.liveEntries.filter { $0.translationStatus != "translation" }
        guard !all.isEmpty else { return "" }
        let maxMs = all.map(\.startMs).max() ?? 0
        let windowMs = Int((maxSeconds ?? Self.contextWindowSeconds) * 1000)
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
        let kind: ModeKind = .meeting
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
        if pendingScreenContext != nil {
            labels.append("Screen OCR")
        }
        return labels
    }

    func toolPreviewLabels() -> [String] {
        ["Screen", "Vault", "Recent", "Docs", "Grep", "Files"]
    }
}
