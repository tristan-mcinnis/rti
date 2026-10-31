import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

extension LLMController {
    /// The one way a turn's final answer is filed: wait for any checkpoint that
    /// is still inside the store, then write the terminal row.
    ///
    /// The order matters. A checkpoint that lands after the terminal write
    /// would put the turn back to `.streaming`; the store refuses that, and this
    /// keeps it from happening in the first place.
    func persistTerminalTurn(
        _ pending: PendingTurn,
        text: String,
        status: RequestStatus,
        error: String?,
        after checkpoint: Task<Void, Never>?
    ) {
        Task { @MainActor [weak self] in
            await checkpoint?.value
            await self?.persistTurnResult(pending, text: text, status: status, error: error)
        }
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages.
    ///
    /// The active retained-source archive goes with them. It is context for the
    /// chat that is ending, not saved history: the thread and its attachment
    /// bytes stay on disk, and a resumed chat rehydrates only its own sources.
    /// Leaving it here is what used to put a previous chat's documents and
    /// images on the wire after `/new` or at the start of the next recording.
    func resetMemory(resumingChatID: String? = nil) {
        resumeRequestID = nil
        NotificationCenter.default.post(
            name: .rtiComposerWillResetConversation, object: self,
            userInfo: resumingChatID.map { ["resumingChatID": $0] }
        )
        pendingDraftRestore = nil
        cancel()
        clearPendingScreenContext()
        entries = []
        progressStatus = [:]
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        clearRetainedSources()
        // The chat's identity changed: an in-flight send may no longer write
        // into it or start a provider call on its behalf.
        generation &+= 1
    }

    /// Drop the active retained-source archive and its notice. The saved thread
    /// and its assets are untouched.
    private func clearRetainedSources() {
        retainedSources = []
        retainedSourceNotice = nil
    }

    /// Start a new chat: `/new` and `/clear`.
    ///
    /// Clears the pending context around the composer — the streaming answer,
    /// the screen read waiting to send — and puts this chat's model choice
    /// back to the app default. It never ends the recording and never discards
    /// the thread that was already recorded: the turns stay in the vault log
    /// and in the session archive.
    func newChat() {
        let plan = ChatResetPlan.forNewChat
        // resetMemory retires the composer's queue before cancelling the stream.
        resetMemory()
        if plan.resetsModelSelection {
            chatSelection = ChatModelSelection(
                providerId: LLMProviders.activeId,
                reasoning: smartMode ? .thinking : .fast
            )
        }
        if plan.resetsBroaderSearch {
            broaderSearchEnabled = false
        }
        pendingDatedSources = []
        // A new chat is a new thread: the one just used stays on disk, and the
        // recording is untouched.
        if plan.preservesSavedThread {
            chatThread = nil
        }
        pendingDraftRestore = nil
    }

    /// A dated legacy log (or one entry) handed over from the Chats library.
    ///
    /// Starts a new chat, attaches the seed's exact recorded text as the
    /// source for the next turn, and leaves the seed's prompt editable in the
    /// field. Nothing is sent: the user edits and sends when ready.
    func applyDatedChatSeed(_ seed: ChatLibraryDatedSeed) {
        guard !seed.isEmpty else { return }
        newChat()
        pendingDatedSources = [Self.datedSource(from: seed)]
        pendingDraftRestore = seed.prompt
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
    }

    /// The seed's recorded text as one source. Its bytes are the text itself;
    /// the source path is a metadata-only reference, never read back.
    private static func datedSource(from seed: ChatLibraryDatedSeed) -> ReferencedDocument {
        let name = seed.scope == .entry ? "Dated entry \(seed.title)" : "Dated log \(seed.title)"
        let document = ExtractedDocument.flat(
            kind: .markdown,
            kindLabel: "Dated log",
            name: name,
            text: seed.sourceText
        )
        return ReferencedDocument(
            path: seed.sourcePath ?? name,
            content: seed.sourceText,
            document: document,
            payload: ChatSourcePayload(
                dated: name,
                sourcePath: seed.sourcePath,
                text: seed.sourceText,
                document: document
            )
        )
    }

    /// The current recording's session id, from the injected provider or the
    /// live coordinator. Nil when no recording is running.
    func currentSessionID() -> String? {
        if let sessionIDProvider {
            return sessionIDProvider()
        }
        return SessionCoordinator.shared.isRunning ? SessionCoordinator.shared.currentSessionId : nil
    }

    /// The structured thread for this chat, created on the first send and
    /// resumed from disk when one with the same id already exists. Nil only
    /// when the app has no vault configured, which is the one case where chat
    /// works without persisting, exactly as the turn log already does.
    ///
    /// A store that cannot be created is thrown, not swallowed: the caller
    /// refuses the send and keeps the draft rather than answering with nothing
    /// written down.
    func chatStore() throws -> ChatThreadStore? {
        // An injected store (a test) is used as-is: nil then means "no vault",
        // never a fall back to the live one.
        if storeIsInjected {
            return injectedStore
        }
        if let threadStore {
            return threadStore
        }
        // The shared instance, so the chat library and the assistant write to
        // the same serialized store rather than racing separate ones.
        let store = try ChatThreadStore.shared()
        threadStore = store
        return store
    }

    /// A thread that is already stored, so a resumed chat continues instead of
    /// starting over. Throws on a damaged record, which is exactly when the
    /// caller must not write.
    func resumeThread(id: String) async throws -> ConversationRecord? {
        guard let store = try chatStore(), store.contains(id: id) else { return nil }
        let thread = try await store.load(id: id)
        chatThread = thread
        // Adopting a thread here does not swap the live entries, so the active
        // source archive must not survive pointing at the chat that was just
        // left behind. Drop it: no stale document or image can then ride a turn
        // filed into the adopted thread. The thread and its own bytes stay on
        // disk; `resumeChat(id:)` is the path that restores them.
        clearRetainedSources()
        return thread
    }

    /// Resume a stored thread in the live chat.
    ///
    /// The old thread stays on disk; this one becomes the current chat, so the
    /// next turn appends to it. The chosen model is restored from the thread's
    /// own last turn (falling back to this chat's current choice), and the
    /// stored attachment references are drawn again. Nothing here touches the
    /// recording, and an answer that is streaming is stopped first.
    func resumeChat(id: String) async {
        let requestID = UUID()
        resumeRequestID = requestID
        var succeeded = false
        defer {
            let isLatestRequest = resumeRequestID == requestID
            if isLatestRequest {
                resumeRequestID = nil
            }
            if succeeded || isLatestRequest {
                NotificationCenter.default.post(
                    name: .rtiComposerDidFinishResume, object: self,
                    userInfo: ["conversationID": id, "succeeded": succeeded]
                )
            }
        }
        do {
            guard let store = try chatStore() else {
                lastError = "No vault is configured, so stored chats cannot be read."
                lastErrorIsAuth = false
                lastErrorTurnID = nil
                return
            }
            guard store.contains(id: id) else {
                lastError = "That chat is no longer in the store."
                lastErrorIsAuth = false
                lastErrorTurnID = nil
                return
            }
            // A queued follow-up belongs to the chat being left. Disarm it
            // before an await or cancellation can finish that chat's stream;
            // preserve the draft if the saved record cannot be opened.
            NotificationCenter.default.post(name: .rtiComposerWillSwitchConversation, object: self)
            guard resumeRequestID == requestID, !Task.isCancelled else { return }
            cancel()
            guard resumeRequestID == requestID, !Task.isCancelled else { return }
            // A turn a process death left mid-answer becomes a cancelled turn
            // before anything is shown, so the chat tells the truth.
            let marked = try await store.markInterrupted(id: id)
            guard resumeRequestID == requestID, !Task.isCancelled else { return }
            if marked > 0 {
                RTILog.log("marked \(marked) interrupted turn(s) in \(id)", category: .llm)
            }
            let thread = try await store.load(id: id)
            guard resumeRequestID == requestID, !Task.isCancelled else { return }
            let retained = try await store.retainedAttachments(id: id)
            guard resumeRequestID == requestID, !Task.isCancelled else { return }

            resetMemory(resumingChatID: id)
            chatThread = thread
            entries = Self.entries(from: thread)
            retainedSources = retained.map(Self.referencedDocument(from:))
            retainedSourceNotice = Self.missingNotice(retained)
            chatSelection = Self.selection(from: thread, fallback: chatSelection)
            broaderSearchEnabled = false
            lastError = nil
            lastErrorIsAuth = false
            lastErrorTurnID = nil
            succeeded = true
        } catch {
            guard resumeRequestID == requestID, !Task.isCancelled else { return }
            // A damaged record is reported, never replaced with an empty chat.
            lastError = "Could not open that chat: \(error.localizedDescription)"
            lastErrorIsAuth = false
            lastErrorTurnID = nil
        }
    }

    /// A retained attachment as a source for the next turn. The extractor's
    /// record travels with it, so a follow-up selects passages with their
    /// locations instead of pasting the whole text. Its bytes come from the
    /// store, never from a path.
    private static func referencedDocument(
        from retained: ChatThreadStore.RetainedAttachment
    ) -> ReferencedDocument {
        let payload = ChatSourcePayload(
            retained: retained.name,
            kind: retained.kind,
            path: retained.path,
            originalBytes: retained.originalBytes,
            normalizedImage: retained.normalizedImage,
            normalizedImageMimeType: retained.normalizedImageMimeType,
            extractedText: retained.extractedText,
            document: retained.document
        )
        return ReferencedDocument(
            path: retained.path ?? ExternalDocumentAttachment.attachedFilePrefix + retained.name,
            content: retained.extractedText ?? "",
            document: retained.document,
            payload: payload
        )
    }

    /// A typed payload as a source for the next turn. Used to hydrate what a
    /// turn was just sent, so a follow-up reads the same bytes with no reread.
    private static func referencedDocument(from payload: ChatSourcePayload) -> ReferencedDocument {
        ReferencedDocument(
            path: payload.path ?? ExternalDocumentAttachment.attachedFilePrefix + payload.name,
            content: payload.extractedText ?? "",
            document: payload.document,
            payload: payload
        )
    }

    /// The honest line for a thread whose stored bytes are partly gone. Nothing
    /// is refetched or re-read from disk.
    private static func missingNotice(_ retained: [ChatThreadStore.RetainedAttachment]) -> String? {
        let missing = retained.filter(\.isMissing).map(\.name)
        guard !missing.isEmpty else { return nil }
        return "Some saved sources are no longer readable from this chat's store (\(missing.joined(separator: ", "))). They are not refetched; the answer uses what was kept."
    }

    /// The thread redrawn as chat entries: words plus the attachment
    /// references, so a resumed chat shows what it was sent.
    private static func entries(from thread: ConversationRecord) -> [ChatEntry] {
        thread.turns.map { turn in
            ChatEntry(
                role: turn.role == .assistant ? "assistant" : "user",
                text: turn.text,
                action: nil,
                contextUsed: false,
                screenContextUsed: false,
                attachments: turn.attachments.map(attachmentRef(from:))
            )
        }
    }

    private static func attachmentRef(from record: AttachmentRecord) -> ChatAttachmentRef {
        let kind: ChatAttachmentRef.Kind = switch record.kind {
        case .pdf: .pdf
        case .image: .image
        case .screenshot: .screen
        case .text, .markdown, .code: .text
        default: .vaultFile
        }
        return ChatAttachmentRef(
            kind: kind,
            name: record.name,
            path: record.path,
            byteCount: record.byteCount,
            pageCount: record.pageCount,
            wasCut: record.truncation != nil
        )
    }

    /// The model the thread last ran on, so resuming a chat restores its
    /// choice rather than whatever the app default happens to be now.
    private static func selection(
        from thread: ConversationRecord,
        fallback: ChatModelSelection
    ) -> ChatModelSelection {
        guard let choice = thread.turns.reversed().compactMap({ $0.model?.chosen }).first else {
            return fallback
        }
        return ChatModelSelection(
            providerId: choice.provider ?? fallback.providerId,
            model: choice.model,
            reasoning: choice.thinking.flatMap(ChatReasoningMode.init(rawValue:)) ?? fallback.reasoning
        )
    }

    /// The result of writing the submitted turn.
    enum PersistOutcome {
        case saved(conversationID: String?)
        /// The app has no vault, so chat runs without persisting.
        case noStore
        /// The chat was replaced (`/new`, a resume) mid-write. The provider
        /// must not start on the old chat's behalf.
        case aborted
        case failed(String)
    }

    /// Save the submitted question and its bytes. The bytes come from the
    /// typed payloads this turn was handed — never re-read from a path — so
    /// one attachment's bytes can never be substituted for another's. Returns
    /// what happened so the caller can keep the draft, abandon a send whose
    /// chat was replaced, or proceed.
    func persistSubmittedTurn(
        userInput: String,
        route: ChatRouteConfiguration,
        toolPolicy: ChatToolPolicy,
        decision: ContextDecision?,
        retrievalStatus: VaultRetrieval.Status?,
        sourceCitations: [String],
        sourcePayloads: [ChatSourcePayload],
        screenPayload: ChatSourcePayload?,
        references: [ReferencedDocument],
        requestSnapshot: Data?,
        parentTurnID: String?,
        conversation: ConversationRecord?,
        sessionID: String?,
        generation: Int
    ) async -> PersistOutcome {
        guard generation == self.generation, !Task.isCancelled else { return .aborted }
        let store: ChatThreadStore
        do {
            if let beforeSubmissionPersistence {
                try await beforeSubmissionPersistence()
            }
            guard generation == self.generation, !Task.isCancelled else { return .aborted }
            guard let created = try chatStore() else { return .noStore }
            store = created
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return .aborted }
            return .failed("Could not open the chat store: \(error.localizedDescription)")
        }

        // Every attachment's bytes come from its own typed payload. There is
        // no switch on a display kind and no path is read here.
        var submitted = sourcePayloads.map(\.submitted)
        if let screenPayload {
            submitted.append(screenPayload.submitted)
        }

        // The recording this turn belongs to, on the turn itself, so a chat
        // created standalone and later continued in a recording is projected
        // exactly instead of by the thread's creation time.
        let turnLinks: [SessionLink] = sessionID.map {
            [SessionLink(kind: "rti-session", id: $0, label: "RTI session")]
        } ?? []

        do {
            let thread: ConversationRecord
            if let conversation {
                thread = conversation
            } else {
                // The link is the recording's own session id, taken from the
                // coordinator that created it, so a session's chats can later
                // be gathered exactly instead of guessed at by time.
                let created = try await store.thread(
                    id: UUID().uuidString,
                    title: nil,
                    surface: sessionID == nil ? .rtiCopilot : .rtiMeeting,
                    session: sessionID.map {
                        SessionLink(kind: "rti-session", id: $0, label: "RTI session")
                    },
                    appVersion: Self.appVersion
                )
                // A `/new` during this write means this send has no chat: do
                // not adopt the created thread, do not write the turn.
                guard generation == self.generation, !Task.isCancelled else { return .aborted }
                thread = created
            }
            guard generation == self.generation, !Task.isCancelled else { return .aborted }
            let commit = try await store.appendTurn(
                to: thread,
                turn: ChatThreadStore.SubmittedTurn(
                    text: userInput,
                    role: .user,
                    model: Self.modelSelection(for: route),
                    request: Self.receipt(
                        route: route,
                        toolPolicy: toolPolicy,
                        decision: decision,
                        retrievalStatus: retrievalStatus,
                        sourceCitations: sourceCitations,
                        sourceCharacters: references.reduce(0) { $0 + $1.content.count },
                        parentTurnID: parentTurnID,
                        status: .pending,
                        error: nil
                    ),
                    sessionLinks: turnLinks,
                    attachments: submitted,
                    requestSnapshot: requestSnapshot
                )
            )
            // A `/new` between the append and here must not reinstate the old
            // thread as the live one.
            guard generation == self.generation, !Task.isCancelled else { return .aborted }
            chatThread = commit.conversation
            // The chat's retained archive accumulates every source it has been
            // sent, deduped by id, so a later bare follow-up can still read
            // them. The wire set for THIS turn is what the policy chose; the
            // archive is separate and never shrinks.
            let accumulated = Self.deduped(retainedSources + references)
            if !accumulated.isEmpty {
                retainedSources = accumulated
            }
            return .saved(conversationID: commit.conversation.id)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return .aborted }
            return .failed("Could not save this question: \(error.localizedDescription)")
        }
    }

    /// Store the answer once it is known: finished, failed, or cancelled. All
    /// three land in the same record with their own status, so an interrupted
    /// turn is not a turn that vanished.
    ///
    /// The write targets the thread the turn was COMMITTED to, not whatever
    /// chat is live now: `/new` or a resume must not mis-file the answer.
    private func persistTurnResult(
        _ pending: PendingTurn,
        text: String,
        status: RequestStatus,
        error: String?
    ) async {
        guard let conversationID = pending.conversationID else { return }
        do {
            guard let store = try chatStore() else { return }
            let thread: ConversationRecord
            do {
                thread = try await store.load(id: conversationID)
            } catch {
                RTILog.log("could not file the answer: chat \(conversationID) is unreadable: \(error)", category: .llm)
                return
            }
            let finishedAt = Date()
            let totalSeconds = finishedAt.timeIntervalSince(pending.startedAt)
            let firstTokenSeconds = pending.firstTokenAt.map { $0.timeIntervalSince(pending.startedAt) }
            // Measured from the user's enqueue time, not from a second Date()
            // taken beside `startedAt` (which would always read ~0). Nil when
            // the send did not measure an enqueue.
            let preparationSeconds = pending.enqueuedAt.map { pending.preparedAt.timeIntervalSince($0) }
            var receipt = Self.receipt(
                route: pending.route,
                toolPolicy: pending.toolPolicy,
                decision: pending.decision,
                retrievalStatus: pending.retrievalStatus,
                sourceCitations: pending.sourceCitations,
                parentTurnID: pending.parentTurnID,
                status: status,
                error: error
            )
            receipt.finishedAt = finishedAt
            var requestTimings = RequestTimings(
                totalSeconds: totalSeconds,
                firstTokenSeconds: firstTokenSeconds,
                toolSeconds: Double(pending.toolElapsedMS) / 1000,
                retrievalSeconds: pending.retrievalSeconds,
                extractionSeconds: preparationSeconds
            )
            if let persistedAt = pending.persistedAt {
                requestTimings.extra["persistenceSeconds"] = .number(persistedAt.timeIntervalSince(pending.preparedAt))
            }
            receipt.timings = requestTimings
            receipt.toolRounds = Self.toolRounds(from: pending.toolCalls)

            let commit = try await store.appendTurn(
                to: thread,
                turn: ChatThreadStore.SubmittedTurn(
                    id: pending.id.uuidString,
                    text: text,
                    role: .assistant,
                    model: Self.modelSelection(for: pending.route),
                    request: receipt,
                    toolRounds: receipt.toolRounds,
                    timings: TurnTimings(
                        extractionSeconds: preparationSeconds,
                        firstTokenSeconds: firstTokenSeconds,
                        totalSeconds: totalSeconds
                    ),
                    error: error,
                    sessionLinks: pending.sessionLinks
                )
            )
            // Adopt the commit only if this is still the live chat; an answer
            // that finished after `/new` stays filed in its own thread.
            if chatThread?.id == conversationID {
                chatThread = commit.conversation
            }
        } catch {
            // The answer already streamed, so there is no draft to keep and
            // nothing to undo. Being loud is the only honest option.
            RTILog.log("could not file the answer in the chat thread: \(error)", category: .llm)
        }
    }

    /// The receipt shared by the question and its answer: which model ran, what
    /// the retrieval policy allowed, what the tools did, and how long it took.
    private static func receipt(
        route: ChatRouteConfiguration,
        toolPolicy: ChatToolPolicy,
        decision: ContextDecision?,
        retrievalStatus: VaultRetrieval.Status? = nil,
        sourceCitations: [String] = [],
        sourceCharacters: Int? = nil,
        parentTurnID: String? = nil,
        status: RequestStatus,
        error: String?
    ) -> RequestReceipt {
        var receipt = RequestReceipt(
            selection: modelSelection(for: route),
            status: status,
            startedAt: Date(),
            error: error
        )
        // A genuine no-match is not an unavailable scan.
        let matched: Bool?
        let complete: Bool?
        switch retrievalStatus {
        case .available: matched = true; complete = true
        case .noMatch: matched = false; complete = true
        case .unavailable: matched = false; complete = false
        case nil: matched = nil; complete = nil
        }
        var rationale = decision?.rationale ?? toolPolicy.rationale
        if let reason = retrievalStatus?.reason {
            rationale += " · retrieval: \(reason)"
        }
        let context = ContextReceipt(
            scope: decision?.execution,
            sourceFirst: decision?.sourceFirst,
            historyIncluded: decision?.includesHistory,
            budgetCharacters: sourceCharacters == nil ? nil : LLMController.attachmentTotalBudgetCharacters,
            sourceCharacters: sourceCharacters,
            coverageLabels: sourceCitations.isEmpty ? nil : sourceCitations,
            matched: matched,
            complete: complete,
            rationale: rationale
        )
        receipt.context = context
        receipt.extra["externalRetrieval"] = .bool(toolPolicy.allowsExternalRetrieval)
        receipt.extra["imageRoute"] = .string(route.imageRoute.rawValue)
        // The actual number of images the frozen route carried.
        receipt.extra["imageCount"] = .number(Double(route.imageCount))
        receipt.extra["toolPolicy"] = .string(toolPolicy.rationale)
        // The versioned record's prompt provenance: which app build shaped the
        // system prompt, and the immutable parent when this turn regenerates
        // another. The full prompt body is the stored request snapshot.
        if let appVersion {
            receipt.extra["promptVersion"] = .string(appVersion)
        }
        if let parentTurnID {
            receipt.extra["parentTurnID"] = .string(parentTurnID)
            receipt.extra["regenerated"] = .bool(true)
        }
        if let retrievalStatus {
            receipt.extra["retrievalStatus"] = .string(Self.statusName(retrievalStatus))
            if let reason = retrievalStatus.reason {
                receipt.extra["retrievalReason"] = .string(reason)
            }
        }
        return receipt
    }

    /// The state as a stable word, for a receipt field.
    static func statusName(_ status: VaultRetrieval.Status) -> String {
        switch status {
        case .available: "available"
        case .noMatch: "noMatch"
        case .unavailable: "unavailable"
        }
    }

    /// The one line a surface shows for a retrieval state. A no-match is a
    /// real answer; a degradation names its cause.
    static func statusDiagnostic(_ status: VaultRetrieval.Status) -> String? {
        switch status {
        case .available:
            nil
        case .noMatch:
            "Vault search found nothing for that question."
        case let .unavailable(reason):
            "Vault search is unavailable: \(reason)"
        }
    }

    /// Group the flat call trace into one round per loop iteration, which is
    /// what the schema calls a tool round.
    static func toolRounds(from traces: [ToolCallTrace]) -> [ToolRound] {
        var rounds: [ToolRound] = []
        for (index, round) in Set(traces.map(\.round)).sorted().enumerated() {
            let calls = traces.filter { $0.round == round }
            // A round is only a success when every call in it succeeded.
            let status: ToolRoundStatus = if calls.contains(where: { $0.status == .failed }) {
                .failed
            } else if !calls.isEmpty, calls.allSatisfy({ $0.status == .refused }) {
                .refused
            } else {
                .succeeded
            }
            rounds.append(ToolRound(index: index, calls: calls.map(\.schemaCall), status: status))
        }
        return rounds
    }

    /// The frozen route in the shared schema's shape: chosen vs effective, so
    /// a later audit can see a vision fallback or a thinking downgrade.
    static func modelSelection(for route: ChatRouteConfiguration) -> ModelSelection {
        ModelSelection(
            chosen: ModelChoice(
                provider: route.selection.providerId,
                model: route.selection.model,
                thinking: route.selection.reasoning.rawValue
            ),
            effective: ModelChoice(
                provider: route.provider.id,
                model: route.provider.model,
                thinking: route.thinkingSent ? ChatReasoningMode.thinking.rawValue : ChatReasoningMode.fast.rawValue
            )
        )
    }

    /// The credential-free body of the request: the model, the messages, and
    /// the facts about the route and the retrieval policy. Built from values
    /// only, so a header, a key, or a base URL cannot reach it.
    static func requestSnapshot(
        route: ChatRouteConfiguration,
        messages: [LLMMessage],
        toolPolicy: ChatToolPolicy,
        decision: ContextDecision?
    ) -> Data? {
        var body: [String: Any] = [
            "model": route.model,
            "provider": route.provider.id,
            "reasoning": route.reasoning.rawValue,
            "imageRoute": route.imageRoute.rawValue,
            "externalRetrieval": toolPolicy.allowsExternalRetrieval,
        ]
        if let decision {
            body["contextRationale"] = decision.rationale
        }
        if let encoded = try? JSONEncoder().encode(messages),
           let decoded = try? JSONSerialization.jsonObject(with: encoded)
        {
            body["messages"] = decoded
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Clear the in-memory chat and start a new one. Byte-for-byte the old
    /// `clear()` behaviour, plus the per-chat model reset.
    func clear() {
        newChat()
    }

    /// Point this chat at another provider. The app default follows, so the
    /// next chat starts where this one did; an answer already streaming keeps
    /// the route it froze with.
    func selectChatProvider(_ id: String) {
        LLMProviders.activeId = id
        chatSelection.providerId = id
        chatSelection.model = nil
    }

    /// This chat's reasoning choice. The app-level Smart mode default follows
    /// so the two controls can never disagree.
    func setChatReasoning(_ mode: ChatReasoningMode) {
        smartMode = mode == .thinking
    }

    /// The visible route label: provider, model, reasoning. The composer and
    /// the thread draw this so the destination is named before Send and on
    /// each answer.
    var chatRouteLabel: String {
        let option = LLMProviders.option(id: chatSelection.providerId)
        return "\(option.displayName) · \(option.config.model) · \(chatSelection.reasoning.label)"
    }
}
