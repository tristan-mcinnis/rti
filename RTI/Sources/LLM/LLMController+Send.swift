import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

extension LLMController {
    func performSend(
        userInput: String,
        action: String,
        fullTranscript: Bool = false,
        transcriptSeconds: Double? = nil,
        forceSmart: Bool = false,
        referencedDocuments: [ReferencedDocument] = [],
        retrievalContext: String? = nil,
        initialTrace: String? = nil,
        attachments: [ChatAttachmentRef] = [],
        sourcePayloads: [ChatSourcePayload] = [],
        /// What the turn's sources are, by origin, for the prompt's own
        /// sentence. Empty when the turn carries no source.
        sourceContext: TurnSourceContext = TurnSourceContext(),
        initialTools: [ChatToolLine] = [],
        initialSources: [ChatSource] = [],
        retrievalSeconds: Double? = nil,
        enqueuedAt: Date? = nil,
        consumedDatedSources: [ReferencedDocument] = [],
        toolPolicy: ChatToolPolicy = ChatToolPolicy(allowsExternalRetrieval: true),
        decision: ContextDecision? = nil,
        retrievalStatus: VaultRetrieval.Status? = nil
    ) {
        guard !streaming else { return }
        sendTask?.cancel()
        request.cancel()
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        toolStatus = nil
        // A regenerate records its immutable parent once, then clears it so a
        // later unrelated send never inherits it, and a blocked route does not
        // leak it onward.
        let parentTurnID = regenerationParentTurnID
        regenerationParentTurnID = nil

        let transcript = recentTranscriptText(fullWindow: fullTranscript, maxSeconds: transcriptSeconds)
        let manualScreenContext = pendingScreenContext
        let pendingImageData = pendingScreenImage
        clearPendingScreenContext()

        let manualScreenRead = !(manualScreenContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // A screenshot is sent when its IMAGE was captured, even with no OCR
        // text: the picture itself is the attachment.
        let screenAttached = (pendingImageData?.isEmpty == false) || manualScreenRead
        let screenPayload: ChatSourcePayload? = screenAttached
            ? ChatSourcePayload(screenJPEG: pendingImageData, ocrText: manualScreenContext)
            : nil

        // Every image this turn would carry, from each source's own normalized
        // bytes: the tray attachments, the retained sources, and the screen
        // capture. The SAME set the composer counts, so the preview route and
        // the frozen route agree.
        let imagePayloads = (referencedDocuments.compactMap(\.payload) + [screenPayload].compactMap { $0 })
            .filter { $0.normalizedImage?.isEmpty == false }
        let imageCount = imagePayloads.count

        // Freeze the route for this turn before anything else is built: the
        // provider, the model, the reasoning choice, and whether images may
        // leave the Mac. A missing key stops here with a reason instead of
        // switching provider behind the user's back. An image the chosen model
        // cannot read is not a failure: the route records that it stays on
        // this Mac and is labelled, so the turn is never silently downgraded.
        let route: ChatRouteConfiguration
        switch resolveTurnRoute(
            imageCount: imageCount,
            forceSmart: forceSmart
        ) {
        case let .success(resolved):
            route = resolved
        case let .failure(blocker):
            postLocalTurn(userInput: userInput, action: action, output: blocker.message)
            return
        }
        let effectiveSmart = route.smart
        // The route decides whether the pictures themselves go to the provider.
        let runtimeImages: [LLMImage] = route.allowsImages
            ? imagePayloads.compactMap { payload in
                guard let data = payload.normalizedImage, !data.isEmpty else { return nil }
                return LLMImage(jpegData: data, mimeType: payload.normalizedImageMimeType ?? "image/jpeg")
            }
            : []
        let ambientScreenContext = ambientScreenRead()
        let screenContext = [ambientScreenContext, manualScreenContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
        let screenUsed = !screenContext.isEmpty

        // What the attached sources contribute: chosen passages, their
        // citations, and an honest line when the selection is partial or
        // matched nothing.
        let sourceSelection = referencedDocumentsText(referencedDocuments, question: userInput)

        let activeMode = modeStore.activeMode
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
            transcriptWindowMinutes: Int((transcriptSeconds ?? Self.contextWindowSeconds) / 60),
            workstreamScopePath: MeetingContextStore.shared.workstreamScopePath,
            hasWorkstreamName: MeetingContextStore.shared.workstreamName != nil,
            priorSuggestions: priorSuggestions(action: action),
            sourceContext: sourceContext,
            externalRetrievalAllowed: toolPolicy.allowsExternalRetrieval,
            retrievalContext: retrievalContext,
            baseSystemPrompt: basePrompt,
            listenerSystemSuffix: PromptStore.shared.text(.listenerSystemSuffix),
            listenerMode: listenerMode,
            meetingContext: MeetingContextStore.shared.combined,
            meetingBrief: MeetingContextStore.shared.briefContext,
            glossaryFragment: GlossaryStore.shared.systemPromptFragment,
            referenceText: activeMode?.referenceText,
            referenceModeName: activeMode?.name,
            screenContext: screenUsed ? screenContext : nil,
            images: runtimeImages,
            referencedDocumentsText: sourceSelection.text,
            existingEntries: entries
        ))

        // Turn records for the thread: what went with the question, and what
        // the answer read before the model ran. Display only.
        let ambientTrailPresent = !(ambientScreenContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var sentAttachments = attachments
        if screenAttached, !sentAttachments.contains(where: { $0.kind == .screen }) {
            sentAttachments.append(ChatAttachmentRef(kind: .screen, name: "Screenshot"))
        }
        var answerTools = ChatTurnRecordBuilder.contextLines(
            transcriptMinutes: turn.contextUsed ? transcriptWindowMinutes(fullWindow: fullTranscript, maxSeconds: transcriptSeconds) : nil,
            wholeTranscript: fullTranscript,
            screenRead: screenAttached,
            screenFromTrail: ambientTrailPresent
        )
        for line in initialTools {
            answerTools = ChatTurnRecordBuilder.appending(line, to: answerTools)
        }
        // An honest line when the attached-source selection was partial or
        // matched nothing, so a thin answer is explained rather than guessed at.
        if let sourceNotice = sourceSelection.diagnostic {
            answerTools = ChatTurnRecordBuilder.appending(
                ChatToolLine(kind: .other, text: sourceNotice),
                to: answerTools
            )
        }

        let userEntry = ChatEntry(
            role: "user",
            text: userInput,
            action: action,
            contextUsed: turn.contextUsed,
            screenContextUsed: screenAttached,
            referencedPaths: referencedDocuments.map(\.path),
            attachments: sentAttachments
        )
        entries.append(userEntry)

        let apiMessages = turn.apiMessages

        let assistantEntry = ChatEntry(
            role: "assistant", text: "", action: nil, contextUsed: false, screenContextUsed: false,
            tools: answerTools, sources: initialSources
        )
        streamingEntryID = assistantEntry.id
        entries.append(assistantEntry)

        // The recording this turn belongs to, resolved now so the turn carries
        // its own exact link instead of relying on the thread's creation time.
        let turnSessionID = currentSessionID()
        // The chat generation this send belongs to. A `/new` or resume that
        // lands while the question is being written must not let this send
        // start a provider call on the old chat's behalf.
        let capturedGeneration = self.generation
        let targetThread = chatThread

        pendingTurn = PendingTurn(
            id: assistantEntry.id,
            ts: Self.iso8601.string(from: Date()),
            startedAt: Date(),
            action: action,
            mode: activeMode?.name,
            route: route,
            toolPolicy: toolPolicy,
            inSession: turnSessionID != nil,
            contextUsed: turn.contextUsed,
            screenUsed: screenAttached,
            userInput: userInput,
            transcriptContext: transcript,
            firstTokenAt: nil,
            toolElapsedMS: 0,
            toolCount: 0,
            toolCalls: [],
            sources: initialTrace.map(sourcePaths(in:)) ?? [],
            decision: decision,
            retrievalStatus: retrievalStatus,
            sourceCitations: sourceSelection.citations,
            conversationID: nil,
            generation: capturedGeneration,
            preparedAt: Date(),
            enqueuedAt: enqueuedAt,
            persistedAt: nil,
            sessionLinks: turnSessionID.map {
                [SessionLink(kind: "rti-session", id: $0, label: "RTI session")]
            } ?? [],
            parentTurnID: parentTurnID,
            retrievalSeconds: retrievalSeconds
        )

        streaming = true
        reasoning = false
        let thisEntryID = assistantEntry.id

        let toolsJSON = LLMToolRegistry.wireFormatData(policy: toolPolicy)
        let requestSnapshot = Self.requestSnapshot(
            route: route,
            messages: apiMessages,
            toolPolicy: toolPolicy,
            decision: decision
        )

        sendTask = Task { [weak self] in
            guard let self else { return }
            // Persist what was submitted — the question, the attachment bytes
            // and the extracted text — BEFORE the provider is called. A
            // failure keeps the draft, drops the half-made turn, and never
            // calls the model. The bytes are the typed payloads this turn was
            // handed; nothing is re-read from a path.
            let outcome = await self.persistSubmittedTurn(
                userInput: userInput,
                route: route,
                toolPolicy: toolPolicy,
                decision: decision,
                retrievalStatus: retrievalStatus,
                sourceCitations: sourceSelection.citations,
                sourcePayloads: sourcePayloads,
                screenPayload: screenPayload,
                references: referencedDocuments,
                requestSnapshot: requestSnapshot,
                parentTurnID: parentTurnID,
                conversation: targetThread,
                sessionID: turnSessionID,
                generation: capturedGeneration
            )
            // A replaced or cancelled send owns none of the current UI state,
            // even if an old storage operation completed without cancellation.
            guard self.generation == capturedGeneration,
                  self.pendingTurn?.id == thisEntryID,
                  !Task.isCancelled else { return }
            switch outcome {
            case let .failed(failure):
                self.entries.removeAll { $0.id == userEntry.id || $0.id == assistantEntry.id }
                self.streaming = false
                self.reasoning = false
                self.streamingEntryID = nil
                self.pendingTurn = nil
                self.lastError = failure
                self.lastErrorIsAuth = false
                self.lastErrorTurnID = nil
                self.pendingDraftRestore = userInput
                RTILog.log("turn not sent: \(failure)", category: .llm)
                return
            case .aborted:
                // The chat the user is in is no longer this turn's. Do not
                // reinstate the old thread and do not start the provider.
                return
            case let .saved(conversationID):
                self.pendingTurn?.conversationID = conversationID
                self.pendingTurn?.persistedAt = Date()
                // The dated source is consumed only once the question is
                // committed. A disk failure or a blocked route keeps the chip
                // and the draft.
                self.clearDatedSources(consumedDatedSources)
            case .noStore:
                self.clearDatedSources(consumedDatedSources)
                break
            }
            // The question is on disk; from here the partial answer is
            // checkpointed periodically so process death leaves a record with
            // the status it was actually in.
            self.startCheckpointing(turnID: thisEntryID)
            let loop = self.makeToolExecutor.map { ToolLoop(request: request, makeToolExecutor: $0) }
                ?? ToolLoop(request: request)
            await loop.run(
                conversation: apiMessages,
                toolsJSON: toolsJSON,
                smart: effectiveSmart,
                route: route,
                allowsExternalRetrieval: toolPolicy.allowsExternalRetrieval,
                allowsScreenTools: toolPolicy.allowsScreenTools,
                onEvent: { event in
                    MainActor.assumeIsolated {
                        guard self.generation == capturedGeneration,
                              self.streamingEntryID == thisEntryID else { return }
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
                        case .toolStarted:
                            self.clearStreamingEntry(thisEntryID)
                        case let .toolFinished(id, round, name, arguments, elapsedMS, result, toolStatus):
                            self.recordToolFinished(
                                id: id,
                                round: round,
                                name: name,
                                arguments: arguments,
                                elapsedMS: elapsedMS,
                                result: result,
                                status: toolStatus,
                                assistantID: thisEntryID
                            )
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
                            // The partial the user could read is the answer to
                            // this failed turn; keep it in the stored row.
                            let partial = self.entries.first { $0.id == thisEntryID }?.text ?? ""
                            self.lastError = message
                            self.lastErrorIsAuth = isAuth
                            self.streaming = false
                            self.reasoning = false
                            self.toolStatus = nil
                            self.pruneTrailingEmptyAssistant()
                            // The failed question stays; its error draws under it.
                            self.lastErrorTurnID = self.entries.last?.role == "user" ? self.entries.last?.id : nil
                            self.streamingEntryID = nil
                            let checkpoint = self.stopCheckpointing()
                            // A failed answer is still a turn: store it with its
                            // error so the thread does not lose the question.
                            let failed = self.pendingTurn
                            self.pendingTurn = nil
                            if let failed {
                                self.persistTerminalTurn(failed, text: partial, status: .failed, error: message, after: checkpoint)
                            }
                            RTILog.log("LLM stream error: \(message)", category: .llm)
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
        // Captured before the turn log clears it: the finished answer is filed
        // in the durable thread with its receipt and tool rounds.
        let finished = pendingTurn
        let finalText = entries.first { $0.id == thisEntryID }?.text ?? ""
        let checkpoint = stopCheckpointing()
        logCompletedTurn(thisEntryID)
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
        if let finished {
            persistTerminalTurn(finished, text: finalText, status: .completed, error: nil, after: checkpoint)
        }
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
            category: .latency
        )
        let record = VaultLogStore.TurnRecord(
            ts: pending.ts, action: pending.action, mode: pending.mode,
            provider: pending.route.provider.id,
            model: pending.route.model,
            smart: pending.route.thinkingSent,
            selectedProvider: pending.route.selection.providerId,
            selectedModel: pending.route.selection.model,
            reasoning: pending.route.reasoning.rawValue,
            thinkingSent: pending.route.thinkingSent,
            imageRoute: pending.route.imageRoute.rawValue,
            imageCount: pending.route.imageCount,
            toolPolicy: pending.toolPolicy.allowsExternalRetrieval ? "external" : "conversation-only",
            inSession: pending.inSession, contextUsed: pending.contextUsed,
            screenUsed: pending.screenUsed, userInput: pending.userInput,
            transcriptContext: pending.transcriptContext, output: output,
            latency: .init(
                totalMs: totalMS,
                firstTokenMs: firstTokenMS,
                toolMs: pending.toolElapsedMS,
                toolCount: pending.toolCount
            ),
            sources: pending.sources,
            toolCalls: pending.toolCalls.isEmpty ? nil : pending.toolCalls.map(\.legacyRecord),
            threadID: pending.conversationID,
            turnID: pending.id.uuidString
        )
        (turnLogger ?? { VaultLogStore.append($0) })(record)
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

    /// Retrieval scope is explicit project first; otherwise infer a project from
    /// the question text ("acmewear" should hit "Acme Wear") before falling
    /// back to whole-vault RAG.
    static func retrievalScope(for query: String) -> String? {
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

    func pruneTrailingEmptyAssistant() {
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

    func prepareAskInput(_ input: String, attachments: [ExternalDocumentAttachment] = []) -> (userInput: String?, references: [ReferencedDocument], error: String?) {
        let mentionResult = Self.extractMentionTokens(from: input)
        // The typed attachment travels whole: original bytes, normalized image,
        // real path, size, cut flag and the extractor's record. Nothing here
        // collapses it to a name for persistence to re-read later.
        var references = attachments.map {
            ReferencedDocument(
                path: $0.wirePath,
                content: $0.text,
                document: $0.document,
                payload: ChatSourcePayload(from: $0)
            )
        }
        for token in mentionResult.tokens {
            switch VaultFiles.resolveMention(token, scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath) {
            case let .resolved(path, content, bytes, wasCut):
                let name = path.split(separator: "/").last.map(String.init) ?? path
                references.append(ReferencedDocument(
                    path: path,
                    content: content,
                    document: nil,
                    payload: ChatSourcePayload(
                        name: name,
                        path: path,
                        text: content,
                        bytes: bytes,
                        document: nil,
                        wasCut: wasCut
                    )
                ))
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

    /// The source text a turn carries.
    ///
    /// When the extractor recorded sections, `DocumentContext` chooses the
    /// passages the question needs — up to 12 chunks per attachment, 2,000
    /// characters per chunk with 200 of overlap — under the per-attachment and
    /// total caps, and reports what it could not cover. Without sections (a
    /// legacy record, or a plain `@` mention read as text) the whole text goes,
    /// which is what it always did.
    private func referencedDocumentsText(
        _ documents: [ReferencedDocument],
        question: String
    ) -> (text: String?, citations: [String], diagnostic: String?) {
        guard !documents.isEmpty else { return (nil, [], nil) }

        let withSections = documents.enumerated().filter { $0.element.document?.sections.isEmpty == false }
        guard !withSections.isEmpty else {
            let text = documents.map { "## \($0.path)\n\n\($0.content)" }.joined(separator: "\n\n")
            return (text, [], nil)
        }

        let plan = DocumentContext.standard.select(
            query: question,
            documents: withSections.map { index, doc in
                AttachmentDocument(attachmentID: "\(index)", document: doc.document!)
            },
            budget: Self.attachmentTotalBudgetCharacters,
            intent: ContextPolicy.standard.classify(question)
        )

        var blocks: [String] = []
        var citations: [String] = []
        var diagnostics: [String] = []
        var used: Set<Int> = []
        for (index, doc) in documents.enumerated() {
            guard let selection = plan.selections["\(index)"] else {
                blocks.append("## \(doc.path)\n\n\(doc.content)")
                continue
            }
            used.insert(index)
            let chosen = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if chosen.isEmpty {
                blocks.append("## \(doc.path)\n\n\(selection.note ?? "No passage in this document matched the question.")")
            } else {
                var block = "## \(doc.path)"
                if !selection.labels.isEmpty { block += "\n\n_" + selection.labels.joined(separator: " · ") + "_" }
                block += "\n\n" + chosen
                if let note = selection.note { block += "\n\n_" + note + "_" }
                blocks.append(block)
            }
            citations.append(contentsOf: selection.labels.map { "\(doc.path) · \($0)" })
            if let note = selection.note { diagnostics.append(note) }
            if !selection.isComplete { diagnostics.append("Not the whole document:\(selection.name.map { " \($0)" } ?? "") coverage is partial.") }
        }
        if plan.truncatedByBudget {
            diagnostics.append("The attachment budget cut the selected passages.")
        }
        _ = used

        return (
            blocks.joined(separator: "\n\n"),
            citations,
            diagnostics.isEmpty ? nil : diagnostics.joined(separator: " ")
        )
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

    func postLocalTurn(userInput: String, action: String, output: String) {
        guard !streaming else { return }
        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: false, screenContextUsed: false))
        entries.append(ChatEntry(role: "assistant", text: output, action: nil, contextUsed: false, screenContextUsed: false))
    }

    /// A local search answer, with the retrieval state on its own line. A
    /// no-match and a broken index must not read the same.
    static func searchAnswerText(label: String, retrieval: VaultRetrieval.Response) -> String {
        var text = retrieval.formattedResults
        if let diagnostic = statusDiagnostic(retrieval.status) {
            text += "\n\n_" + diagnostic + "_"
        }
        return text
    }

    func updateLocalAssistant(_ id: UUID, text: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
        if progressStatus[id] != nil { progressStatus[id] = text }
    }

    /// A local search finished: the entry stops being a status and carries
    /// the search's line and sources.
    func finishLocalProgress(_ id: UUID, retrieval: VaultRetrieval.Response, scoped: Bool) {
        progressStatus[id] = nil
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].tools = ChatTurnRecordBuilder.appending(
            ToolTraceParser.searchLine(resultCount: retrieval.results.count, scoped: scoped),
            to: entries[idx].tools
        )
        entries[idx].sources = ChatTurnRecordBuilder.merging(Self.chatSources(retrieval), into: entries[idx].sources)
    }

    func beginLocalProgress(userInput: String, action: String, text: String) -> UUID {
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        streaming = true
        toolStatus = nil
        entries.append(ChatEntry(role: "user", text: userInput, action: action, contextUsed: false, screenContextUsed: false))
        let assistant = ChatEntry(role: "assistant", text: text, action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(assistant)
        streamingEntryID = assistant.id
        progressStatus[assistant.id] = text
        return assistant.id
    }

    func removeLocalProgress(_ assistantID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == assistantID }) else {
            streaming = false
            streamingEntryID = nil
            return
        }
        let userIdx = idx > 0 && entries[idx - 1].role == "user" ? idx - 1 : idx
        entries.removeSubrange(userIdx...idx)
        progressStatus[assistantID] = nil
        streaming = false
        streamingEntryID = nil
        toolStatus = nil
    }

    /// A tool call finished: log it (the four retrieval tools, as before)
    /// and leave its line and sources on the answer for the thread.
    private func recordToolFinished(
        id: String,
        round: Int,
        name: String,
        arguments: String,
        elapsedMS: Int,
        result: String,
        status: ToolRoundStatus,
        assistantID: UUID
    ) {
        pendingTurn?.toolCalls.append(ToolCallTrace(
            round: round,
            id: id,
            name: name,
            arguments: arguments,
            elapsedMS: elapsedMS,
            resultCharacters: result.count,
            status: status,
            error: status == .failed ? String(result.prefix(300)) : nil
        ))
        if status == .succeeded, ChatToolPolicy.discoveryToolNames.contains(name) {
            recordPendingTool(elapsedMS: elapsedMS, sources: sourcePaths(in: result))
        }
        guard let idx = entries.firstIndex(where: { $0.id == assistantID }) else { return }
        if let line = ToolTraceParser.toolLine(forTool: name, result: result) {
            entries[idx].tools = ChatTurnRecordBuilder.appending(line, to: entries[idx].tools)
        }
        if name == "search_vault" {
            entries[idx].sources = ChatTurnRecordBuilder.merging(
                ToolTraceParser.sources(inSearchResult: result),
                into: entries[idx].sources
            )
        }
    }

    /// A search's hits as sources: title, vault path, and the day it was
    /// last updated.
    static func chatSources(_ retrieval: VaultRetrieval.Response) -> [ChatSource] {
        retrieval.results.map { ChatSource(title: $0.title, path: $0.relativePath, date: $0.modified) }
    }

    /// The chips over an Ask, built from the typed sources themselves: a
    /// vault file keeps its path, a document keeps its own size and page
    /// count, and a screen capture stays a screen capture. Never rebuilt from
    /// a name or inferred from a suffix.
    static func attachmentRefs(references: [ReferencedDocument]) -> [ChatAttachmentRef] {
        references.compactMap { ref in
            if let payload = ref.payload {
                return ChatAttachmentRef(
                    kind: payload.displayKind,
                    name: payload.name,
                    path: payload.path,
                    byteCount: payload.byteCount,
                    pageCount: payload.pageCount,
                    wasCut: payload.wasCut
                )
            }
            // A plain vault mention with no typed payload.
            let name = ref.path.split(separator: "/").last.map(String.init) ?? ref.path
            return ChatAttachmentRef(kind: .vaultFile, name: name, path: ref.path)
        }
    }

    /// The screenshot for this turn, or nil when the active provider cannot
    /// take image input (then the OCR text is the whole attachment).
    /// Minutes of transcript the next turn reads: the same window
    /// `recentTranscriptText` builds, first line to last.
    private func transcriptWindowMinutes(fullWindow: Bool, maxSeconds: Double? = nil) -> Int {
        let all = SessionCoordinator.shared.liveEntries.filter { $0.translationStatus != "translation" }
        guard let maxMs = all.map(\.startMs).max() else { return 1 }
        let windowMs = Int((maxSeconds ?? Self.contextWindowSeconds) * 1000)
        let threshold = fullWindow ? 0 : max(0, maxMs - windowMs)
        let firstMs = all.lazy.filter { $0.startMs >= threshold }.map(\.startMs).min() ?? maxMs
        return ChatTurnRecordBuilder.transcriptMinutes(firstStartMs: firstMs, lastStartMs: maxMs)
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
    func recentAskQuestions(excluding current: String) -> [String] {
        entries
            .filter { $0.role == "user" && $0.action == "Ask" && $0.text != current }
            .suffix(8)
            .map(\.text)
    }

    func lastUserQuestion() -> String {
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
    func recentTranscriptText(fullWindow: Bool = false, maxSeconds: Double? = nil) -> String {
        // Exclude live-translation tokens — the assistant reads the original
        // spoken transcript, not its translated duplicate.
        let all = SessionCoordinator.shared.liveEntries.filter { $0.translationStatus != "translation" }
        guard !all.isEmpty else { return "" }
        let maxMs = all.map(\.startMs).max() ?? 0
        let windowMs = Int((maxSeconds ?? Self.contextWindowSeconds) * 1000)
        let threshold = fullWindow ? 0 : max(0, maxMs - windowMs)
        let windowed = all.filter { $0.startMs >= threshold }

        // Labels come from the speaker id, as in the Transcript tab, so "Speaker
        // 2" in a question and in the answer is the person the tab shows.
        let names = SpeakerNameStore.shared.names
        return TranscriptContext.format(
            windowed,
            label: { TranscriptContext.speakerLabel(for: $0, names: names) },
            noteLabel: "[my note]"
        )
    }
}
