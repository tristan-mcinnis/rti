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
    func reconcileListenerModeForSessionStart() {
        guard listenerMode else { return }
        let name = (ModeStore.shared.activeMode?.name ?? "").lowercased()
        let fieldwork = ["interview", "observ", "fgd", "idi", "fieldwork", "listen"]
            .contains { name.contains($0) }
        if !fieldwork { listenerMode = false }
    }

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

    func sendAskAnything(_ input: String, attachments: [ExternalDocumentAttachment] = []) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let prepared = prepareAskInput(trimmed, attachments: attachments)
        guard let userInput = prepared.userInput else {
            lastError = prepared.error
            lastErrorIsAuth = false
            return
        }
        guard !streaming else { return }
        // An explicit attachment/@mention is already the user's chosen source.
        // Searching the whole vault first both wastes time and can drown it out
        // with unrelated results (e.g. asking "what is this about?"). The
        // model can still use a vault tool if the user specifically asks for a
        // comparison or broader lookup.
        if !prepared.references.isEmpty {
            let label = prepared.references.count == 1
                ? "Attached source"
                : "(prepared.references.count) attached sources"
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                initialTrace: label
            )
            return
        }
        let workstreamNames = (VaultWorkstreamStore.projects() + VaultWorkstreamStore.clients()).map(\.name)
        let recentQuestions = self.recentAskQuestions(excluding: userInput)
        guard Self.shouldSearchVault(
            query: userInput,
            hasSelectedScope: MeetingContextStore.shared.workstreamScopePath != nil,
            workstreamNames: workstreamNames,
            recentQuestions: recentQuestions
        ) else {
            performSend(userInput: userInput, action: "Ask")
            return
        }
        let progressID = beginLocalProgress(
            userInput: userInput,
            action: "Ask",
            text: "Searching the vault…"
        )
        Task { @MainActor in
            let scope = Self.retrievalScope(for: userInput)
            let forceHard = Self.shouldForceVaultSearch(query: userInput, workstreamNames: workstreamNames, recentQuestions: recentQuestions)
            let retrieval = await VaultRetrieval.search(
                query: userInput,
                scopeRelativePath: scope,
                zeroResultPolicy: forceHard ? .hard : .soft
            )
            let sources = retrieval.sourcePaths
            let scopeLabel = scope == nil ? "vault-wide" : "project-scoped"
            updateLocalAssistant(
                progressID,
                text: sources.isEmpty
                    ? "Vault search finished (\(scopeLabel), \(retrieval.elapsedMS)ms). Drafting answer…"
                    : "Found \(sources.count) source\(sources.count == 1 ? "" : "s") (\(scopeLabel), \(retrieval.elapsedMS)ms). Drafting answer…"
            )
            removeLocalProgress(progressID)
            performSend(userInput: userInput, action: "Ask", referencedDocuments: prepared.references, retrievalContext: retrieval.modelContextForQuestion, initialTrace: retrieval.trace)
        }
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
        let progressID = beginLocalProgress(
            userInput: "Answer latest",
            action: "Answer latest",
            text: "Reading the latest transcript point…"
        )
        Task { @MainActor in
            var vaultBlock = ""
            let scope = Self.retrievalScope(for: window)
            updateLocalAssistant(progressID, text: scope == nil ? "Searching the vault for the latest point…" : "Searching this project for the latest point…")
            let retrieval = await VaultRetrieval.search(query: window, scopeRelativePath: scope, zeroResultPolicy: .latestPoint)
            if retrieval.hasResults {
                vaultBlock = "\n\n\(retrieval.scopeLabel) search results for the latest live question/point:\n---\n\(retrieval.formattedResults)\n---"
            } else {
                // Same contract as sendAskAnything: an empty search must reach
                // the model as an explicit zero-result, never silently.
                vaultBlock = "\n\n\(retrieval.modelContextForQuestion)"
            }
            updateLocalAssistant(progressID, text: "Context ready (\(retrieval.elapsedMS)ms). Drafting answer…")
            let prompt = """
            Answer the MOST recent client question, challenge, or decision point in the live transcript.
            If the latest point is answerable from the current transcript, answer directly from that.
            If project context or vault material is relevant, use it and cite the source path briefly.
            Be concise and practical: what should I say now, or what answer should I give?
            Do not narrate the search process. Do not say "let me search" or "I found". Return only the final answer.
            \(vaultBlock)
            """
            removeLocalProgress(progressID)
            performSend(userInput: prompt, action: "Answer latest")
        }
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
            `/search <query>` — fast vault RAG search in the selected project/client, or whole vault if nothing is selected.
            `/sources [query]` — show source hits for a query; if blank, uses your last question.
            `/project [name]` — set project/client context by name. Blank shows current context. Use `/project clear` to go vault-wide.
            `/answer` — answer the latest live question/point.
            `/recent` — ask about recent sessions for the selected project.
            `/screen` — OCR connected screens and attach them to the next message.
            `/note <text>` — add a live transcript note.
            `/new` — clear this chat.

            `@file-or-phrase` attaches a vault document. It searches the selected project/client first, then the whole vault.
            Use **Attach file…** (or drag one in) for a one-turn PDF, Markdown, or text-file attachment; RTI keeps only its in-memory text for that request.
            """
        )
    }

    func sendVaultSearchCommand(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            postLocalTurn(userInput: "/search", action: "Search", output: "Usage: `/search <query>`")
            return
        }
        guard !streaming else { return }
        let userInput = "/search \(trimmed)"
        let assistant = ChatEntry(role: "assistant", text: "Searching vault…", action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(ChatEntry(role: "user", text: userInput, action: "Search", contextUsed: false, screenContextUsed: false))
        entries.append(assistant)
        let assistantID = assistant.id
        Task { @MainActor in
            let scope = Self.retrievalScope(for: trimmed)
            let retrieval = await VaultRetrieval.search(query: trimmed, scopeRelativePath: scope)
            let label = scope == nil ? "Vault-wide search" : "Scoped search"
            toolTraces[assistantID] = retrieval.trace
            updateLocalAssistant(assistantID, text: "**\(label)**\n\n\(retrieval.formattedResults)")
        }
    }

    func sendVaultSourcesCommand(_ query: String?) {
        let fallback = lastUserQuestion()
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? fallback : trimmed
        guard !effective.isEmpty else {
            postLocalTurn(userInput: "/sources", action: "Sources", output: "Usage: `/sources <query>` or run it after asking a question.")
            return
        }
        guard !streaming else { return }
        let userInput = trimmed.isEmpty ? "/sources" : "/sources \(trimmed)"
        let assistant = ChatEntry(role: "assistant", text: "Finding sources…", action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(ChatEntry(role: "user", text: userInput, action: "Sources", contextUsed: false, screenContextUsed: false))
        entries.append(assistant)
        let assistantID = assistant.id
        Task { @MainActor in
            let scope = Self.retrievalScope(for: effective)
            let retrieval = await VaultRetrieval.search(query: effective, scopeRelativePath: scope)
            let label = scope == nil ? "Vault-wide sources" : "Scoped sources"
            toolTraces[assistantID] = retrieval.trace
            updateLocalAssistant(assistantID, text: "**\(label) for:** \(effective)\n\n\(retrieval.formattedResults)")
        }
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
        let ambientScreenContext = SessionCoordinator.shared.isRunning
            ? VisualContextTrail.shared.recentPromptContext()
            : nil
        let screenContext = [ambientScreenContext, manualScreenContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
        let screenUsed = !screenContext.isEmpty

        let activeMode = ModeStore.shared.activeMode
        let basePrompt: String = {
            if let prompt = activeMode?.systemPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return prompt
            }
            return PromptStore.shared.text(.systemDefault)
        }()

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
            meetingBrief: MeetingContextStore.shared.briefContext,
            discussionGuide: DiscussionGuideController.shared.guide?.assistantContextSummary(),
            glossaryFragment: GlossaryStore.shared.systemPromptFragment,
            referenceText: activeMode?.referenceText,
            referenceModeName: activeMode?.name,
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
            mode: activeMode?.name,
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
                            self.markFirstTokenIfNeeded()
                            self.appendToStreamingEntry(delta)
                        case .reasoningStarted:
                            self.reasoning = true
                        case .reasoningEnded:
                            self.reasoning = false
                        case let .toolStatus(status):
                            self.toolStatus = status
                        case let .toolStarted(name, status):
                            self.clearStreamingEntry(thisEntryID)
                            self.recordToolStarted(name: name, status: status, assistantID: thisEntryID)
                        case let .toolFinished(name, elapsedMS, result):
                            self.recordToolFinished(name: name, elapsedMS: elapsedMS, result: result, assistantID: thisEntryID)
                        case .toolStatusDone:
                            self.clearStreamingEntry(thisEntryID)
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
                            self.activeToolTraceLines = []
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

    private func recordPendingTool(elapsedMS: Int, sources: [String]) {
        guard pendingTurn != nil else { return }
        pendingTurn?.toolCount += 1
        pendingTurn?.toolElapsedMS += elapsedMS
        for source in sources where pendingTurn?.sources.contains(source) == false {
            pendingTurn?.sources.append(source)
        }
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

    /// Retrieval scope is explicit project first; otherwise infer a project from
    /// the question text ("acmebrand" should hit "Acme Brand") before falling
    /// back to whole-vault RAG.
    private static func retrievalScope(for query: String) -> String? {
        if let selected = MeetingContextStore.shared.workstreamScopePath { return selected }
        let compactQuery = compactKey(query)
        guard !compactQuery.isEmpty else { return nil }
        let match = VaultWorkstreamStore.projects()
            .filter {
                let key = compactKey($0.name)
                return !key.isEmpty && compactQuery.contains(key)
            }
            .max { compactKey($0.name).count < compactKey($1.name).count }
        guard let match else { return nil }
        return VaultWorkstreamStore.scopeRelativePath(for: match)
    }

    nonisolated private static func compactKey(_ text: String) -> String {
        RetrievalHeuristics.compactKey(text)
    }

    /// Moved to `RetrievalHeuristics` so the test bundle can compile it
    /// without this controller; kept as a passthrough for existing call sites.
    nonisolated static func shouldForceVaultSearch(query: String, workstreamNames: [String], recentQuestions: [String]) -> Bool {
        RetrievalHeuristics.shouldForceVaultSearch(query: query, workstreamNames: workstreamNames, recentQuestions: recentQuestions)
    }

    nonisolated static func shouldSearchVault(query: String, hasSelectedScope: Bool, workstreamNames: [String], recentQuestions: [String]) -> Bool {
        RetrievalHeuristics.shouldSearchVault(
            query: query,
            hasSelectedScope: hasSelectedScope,
            workstreamNames: workstreamNames,
            recentQuestions: recentQuestions
        )
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

    private func clearStreamingEntry(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = ""
    }

    private func prepareAskInput(_ input: String, attachments: [ExternalDocumentAttachment] = []) -> (userInput: String?, references: [ReferencedDocument], error: String?) {
        let mentionResult = Self.extractMentionTokens(from: input)
        var references = attachments.map { ReferencedDocument(path: "Attached file: \($0.name)", content: $0.text) }
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

    private func recordToolStarted(name: String, status: String, assistantID: UUID) {
        guard name == "search_vault" || name == "grep_vault" || name == "recent_meetings" || name == "list_files" else {
            return
        }
        activeToolTraceLines.append("Running \(displayName(forTool: name))")
        toolTraces[assistantID] = activeToolTraceLines.joined(separator: "\n")
    }

    private func recordToolFinished(name: String, elapsedMS: Int, result: String, assistantID: UUID) {
        guard name == "search_vault" || name == "grep_vault" || name == "recent_meetings" || name == "list_files" else {
            return
        }
        let display = displayName(forTool: name)
        let sources = sourcePaths(in: result)
        recordPendingTool(elapsedMS: elapsedMS, sources: sources)
        var line = "\(display) · \(elapsedMS)ms"
        if !sources.isEmpty {
            line += " · \(sources.count) source\(sources.count == 1 ? "" : "s")"
            line += ": " + sources.prefix(3).joined(separator: ", ")
            if sources.count > 3 { line += ", +" + String(sources.count - 3) }
        }
        if let last = activeToolTraceLines.indices.last {
            activeToolTraceLines[last] = line
        } else {
            activeToolTraceLines.append(line)
        }
        toolTraces[assistantID] = activeToolTraceLines.joined(separator: "\n")
    }

    private func displayName(forTool name: String) -> String {
        switch name {
        case "search_vault": return "Vault search"
        case "grep_vault": return "Vault grep"
        case "read_document": return "Read document"
        case "recent_meetings": return "Recent meetings"
        case "list_files": return "List files"
        case "capture_screen": return "Screen OCR"
        default: return name
        }
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

    /// Prior "Ask" questions already typed this session (most recent last),
    /// excluding the one just submitted — feeds the repeat check in
    /// `shouldForceVaultSearch`.
    private func recentAskQuestions(excluding current: String) -> [String] {
        entries
            .filter { $0.role == "user" && $0.action == "Ask" && $0.text != current }
            .suffix(8)
            .map(\.text)
    }

    private func lastUserQuestion() -> String {
        entries.reversed().first { entry in
            entry.role == "user" && ["Ask", "Search", "Sources"].contains(entry.action ?? "")
        }?.text
            .replacingOccurrences(of: #"^/(search|sources)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
