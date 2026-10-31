import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

extension LLMController {
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
        case "quickRecap": sendQuickRecap()
        case "recap": sendRecap()
        case "sayNext": sendSaySomething()
        case "followups": sendFollowupQuestions()
        case "keyTensions": sendKeyTensions()
        case "probe": sendProbe()
        case "themes": sendThemes()
        default: break
        }
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
        // The user's send time, before any preparation, so the preparation
        // timing is a real measurement rather than a same-initializer ~0.
        let enqueuedAt = Date()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        var prepared = prepareAskInput(trimmed, attachments: attachments)
        guard let userInput = prepared.userInput else {
            lastError = prepared.error
            lastErrorIsAuth = false
            lastErrorTurnID = nil
            return
        }
        guard !streaming else { return }
        // A dated legacy log handed over from the library rides this turn as
        // an exact recorded source, ahead of anything new the user attached.
        // It is consumed ONLY on a successful commit (see performSend), so a
        // disk failure or a blocked route keeps the chip and the draft.
        let datedSources = pendingDatedSources
        // The sources handed over FOR THIS TURN: the dated seed plus anything
        // the user attached or mentioned. Retained sources are the chat's
        // archive, not this turn's own source.
        let freshReferences = Self.deduped(datedSources + prepared.references)
        // The payloads the user handed over for THIS turn. Retained sources
        // from earlier turns are already in the store and are not rewritten.
        let freshPayloads = freshReferences.compactMap(\.payload)
        // The wire set and the policy decision are composed together, on the
        // one set the turn will actually carry: a fresh source, or the retained
        // archive when nothing new came. The receipt, the tool policy, the
        // composer preview and the prompt all read this value, so none of them
        // can describe a source set the request did not send.
        let wire = ChatWireSources.compose(
            question: userInput,
            freshSourceCount: freshReferences.count,
            retainedSourceCount: retainedSources.count,
            historyTurnCount: entries.filter { $0.role == "user" }.count,
            historyHasSources: entries.contains { $0.role == "user" && !$0.attachments.isEmpty },
            broaderToggleOn: broaderSearchEnabled
        )
        let decision = wire.decision
        // Fresh first for budget, and an old image is never retransmitted on a
        // fresh-source-scope turn.
        let sentReferences: [ReferencedDocument] = switch wire.choice {
        case .none: []
        case .fresh: freshReferences
        case .retained: retainedSources
        case .freshAndRetained: Self.deduped(freshReferences + retainedSources)
        }
        prepared.references = sentReferences
        // What the turn carries, by origin, for the prompt's own sentence: a
        // newly attached source and one retained from earlier in this chat are
        // named differently, and neither claims the other's origin.
        let sourceContext = TurnSourceContext(
            freshCount: wire.carriesFreshSources ? freshReferences.count : 0,
            retainedCount: wire.carriesRetainedSources ? retainedSources.count : 0
        )
        // The screen tools are a separate permission: only the user's own
        // wording about the screen opens them on a source-first turn.
        let toolPolicy = ChatToolPolicy(
            decision: decision,
            allowsScreenTools: ChatToolPolicy.questionRequestsScreen(userInput)
        )
        RTILog.log(
            "context: external=\(decision.allowsExternalRetrieval) execution=\(decision.execution.rawValue) screen=\(toolPolicy.allowsScreenTools) fresh=\(freshReferences.count) retained=\(retainedSources.count) wire=\(sentReferences.count) — \(decision.rationale)",
            category: .llm
        )
        // An explicit attachment/@mention is already the user's chosen source.
        // Searching the whole vault first both wastes time and can drown it out
        // with unrelated results (e.g. asking "what is this about?"). Broader
        // search, when the user asks for it, lifts that.
        if !toolPolicy.allowsDiscovery {
            let label = prepared.references.count == 1
                ? "Attached source"
                : "\(prepared.references.count) attached sources"
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                initialTrace: prepared.references.isEmpty ? nil : label,
                attachments: Self.attachmentRefs(references: prepared.references),
                sourcePayloads: freshPayloads,
                sourceContext: sourceContext,
                enqueuedAt: enqueuedAt,
                consumedDatedSources: datedSources,
                toolPolicy: toolPolicy,
                decision: decision
            )
            return
        }
        let workstreamNames = (VaultWorkstreamStore.projects() + VaultWorkstreamStore.clients()).map(\.name)
        let recentQuestions = recentAskQuestions(excluding: userInput)
        guard Self.shouldSearchVault(
            query: userInput,
            hasSelectedScope: MeetingContextStore.shared.workstreamScopePath != nil,
            workstreamNames: workstreamNames,
            recentQuestions: recentQuestions
        ) else {
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                attachments: Self.attachmentRefs(references: prepared.references),
                sourcePayloads: freshPayloads,
                sourceContext: sourceContext,
                enqueuedAt: enqueuedAt,
                consumedDatedSources: datedSources,
                toolPolicy: toolPolicy,
                decision: decision
            )
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
            self.retrievalDiagnostic = Self.statusDiagnostic(retrieval.status)
            let sources = retrieval.sourcePaths
            let scopeLabel = scope == nil ? "vault-wide" : "project-scoped"
            updateLocalAssistant(
                progressID,
                text: sources.isEmpty
                    ? "Vault search finished (\(scopeLabel), \(retrieval.elapsedMS)ms). Drafting answer…"
                    : "Found \(sources.count) source\(sources.count == 1 ? "" : "s") (\(scopeLabel), \(retrieval.elapsedMS)ms). Drafting answer…"
            )
            removeLocalProgress(progressID)
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                retrievalContext: retrieval.modelContextForQuestion,
                initialTrace: retrieval.trace,
                attachments: Self.attachmentRefs(references: prepared.references),
                sourcePayloads: freshPayloads,
                sourceContext: sourceContext,
                initialTools: [ToolTraceParser.searchLine(resultCount: retrieval.results.count, scoped: scope != nil)],
                initialSources: Self.chatSources(retrieval),
                retrievalSeconds: Double(retrieval.elapsedMS) / 1000,
                enqueuedAt: enqueuedAt,
                consumedDatedSources: datedSources,
                toolPolicy: toolPolicy,
                decision: decision,
                retrievalStatus: retrieval.status
            )
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
            lastErrorTurnID = nil
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
            performSend(
                userInput: prompt,
                action: "Answer latest",
                initialTools: [ToolTraceParser.searchLine(resultCount: retrieval.results.count, scoped: scope != nil)],
                initialSources: Self.chatSources(retrieval)
            )
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
        guard hasLiveTranscriptForRecap() else { return }
        performSend(userInput: PromptStore.shared.recap(depth ?? recapDepth), action: "Recap")
    }

    /// Quick recap: the last five minutes, one or two bullets — the "catch me
    /// up" turn. The shipped ⌘⏎ primary action, so a listener can glance at
    /// RTI mid-meeting and read what just happened without picking a depth.
    func sendQuickRecap() {
        guard hasLiveTranscriptForRecap() else { return }
        performSend(
            userInput: PromptStore.shared.recap(.brief),
            action: "Quick recap",
            transcriptSeconds: Self.quickRecapWindowSeconds
        )
    }

    /// A recap prompt presupposes a conversation. With an empty live
    /// transcript (before the first line, or while paused) refuse the turn
    /// with the same message Answer latest uses rather than spend a model call
    /// on it. False also means a stream is already running.
    private func hasLiveTranscriptForRecap() -> Bool {
        guard !streaming else { return false }
        guard recentTranscriptText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        lastError = "No live transcript yet."
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        return false
    }

    /// Re-run the turn that produced `assistantID`: drop that assistant reply
    /// (and anything after it), then re-send the user turn it answered.
    /// Transcript context is rebuilt fresh from the current live entries.
    ///
    /// A local turn (a `/search`, a `/project`, a refused command) never
    /// reached the model, so it is not regenerable: replaying its text would
    /// send a slash command as the prompt.
    func regenerate(assistantID: UUID) {
        guard !streaming,
              let assistantIdx = entries.firstIndex(where: { $0.id == assistantID }),
              entries[assistantIdx].role == "assistant" else { return }
        let userIdx = assistantIdx - 1
        guard userIdx >= 0, entries[userIdx].role == "user" else { return }
        let userEntry = entries[userIdx]
        guard !Self.localActionNames.contains(userEntry.action ?? "") else { return }
        // performSend re-appends the user turn, so drop it here too.
        entries.removeSubrange(userIdx...)
        // Record the immutable parent for the replacement turn's receipt.
        regenerationParentTurnID = assistantID.uuidString
        resend(userEntry)
    }

    /// Actions whose turn never reached the model. Their text is a slash
    /// command or a local notice, so it must never be replayed as a prompt.
    private static let localActionNames: Set<String> = ["Search", "Sources", "Project", "Help", "Command"]

    /// Ask the turn `userEntry` asked again, through the path that first
    /// sent it. The entry must already be out of `entries`.
    private func resend(_ userEntry: ChatEntry) {
        let action = userEntry.action ?? "Ask"
        // A local turn is not a model turn; never replay its command as one.
        guard !Self.localActionNames.contains(action) else { return }
        if action == "Ask" {
            // Re-run the deterministic vault search rather than replay through
            // bare performSend, which skipped retrieval entirely and answered
            // from the transcript/priors alone.
            sendAskAnything(userEntry.text)
        } else {
            performSend(userInput: userEntry.text, action: action)
        }
    }

    /// `⌘R` and the error line's Retry: a question whose answer failed is
    /// asked again in its place (one pill, not two); otherwise the newest
    /// answer is regenerated.
    func retryLastTurn() {
        guard !streaming else { return }
        if let failedID = lastErrorTurnID,
           let idx = entries.firstIndex(where: { $0.id == failedID }),
           entries[idx].role == "user"
        {
            let userEntry = entries[idx]
            entries.removeSubrange(idx...)
            lastError = nil
            lastErrorIsAuth = false
            lastErrorTurnID = nil
            resend(userEntry)
        } else if let answer = latestAnswer {
            regenerate(assistantID: answer.id)
        }
    }

    /// The newest finished answer, for Copy Response and Regenerate.
    var latestAnswer: ChatEntry? {
        entries.last { $0.role == "assistant" && !$0.text.isEmpty && $0.id != streamingEntryID && progressStatus[$0.id] == nil }
    }

    /// Replacing or removing an attachment invalidates every suspended reader.
    func beginScreenAttachment(status: String) -> UUID {
        let requestID = UUID()
        screenAttachmentRequestID = requestID
        pendingScreenContext = nil
        pendingScreenImage = nil
        pendingScreenPreview = nil
        screenCaptureStatus = status
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        return requestID
    }

    func isCurrentScreenAttachment(_ requestID: UUID) -> Bool {
        screenAttachmentRequestID == requestID
    }

    func attachScreenContext(_ text: String, image: Data? = nil, requestID: UUID? = nil) {
        if let requestID, !isCurrentScreenAttachment(requestID) {
            return
        }
        screenAttachmentRequestID = nil
        pendingScreenContext = text
        pendingScreenImage = image
        pendingScreenPreview = image.flatMap(NSImage.init(data:))
        screenCaptureStatus = nil
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
    }

    func clearPendingScreenContext() {
        screenAttachmentRequestID = nil
        pendingScreenContext = nil
        pendingScreenImage = nil
        pendingScreenPreview = nil
        screenCaptureStatus = nil
    }

    func setScreenAttachError(_ message: String, requestID: UUID? = nil) {
        if let requestID, !isCurrentScreenAttachment(requestID) {
            return
        }
        screenAttachmentRequestID = nil
        pendingScreenContext = nil
        pendingScreenImage = nil
        pendingScreenPreview = nil
        screenCaptureStatus = message
        lastError = message
        lastErrorIsAuth = false
        lastErrorTurnID = nil
    }

    func setScreenCaptureStatus(_ message: String?, requestID: UUID? = nil) {
        if let requestID, !isCurrentScreenAttachment(requestID) {
            return
        }
        screenCaptureStatus = message
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        request.cancel()
        // The checkpoint write may already be inside the store. Keep its task
        // so the terminal write can wait for it instead of racing it.
        let checkpoint = stopCheckpointing()
        streaming = false
        reasoning = false
        toolStatus = nil
        // The text the user could read at Stop is the answer: read it before
        // the entry is pruned, and keep it in the stored turn.
        let stopped = pendingTurn
        let partial = stopped.flatMap { turn in entries.first { $0.id == turn.id }?.text } ?? ""
        pendingTurn = nil
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
        // A stopped answer is a turn too, with status cancelled, so the
        // question is never left in the thread without its outcome.
        if let stopped {
            persistTerminalTurn(stopped, text: partial, status: .cancelled, error: nil, after: checkpoint)
        }
    }
}
