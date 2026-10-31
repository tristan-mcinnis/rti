import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

extension Notification.Name {
    /// Sent synchronously before a conversation change can cancel a stream.
    /// The object is the controller whose composer must retire its queued turn.
    static let rtiComposerWillSwitchConversation = Notification.Name("rti.composerWillSwitchConversation")
    /// Sent synchronously before a successful reset clears controller context.
    /// Only that controller's composer discards its pending draft and sources.
    static let rtiComposerWillResetConversation = Notification.Name("rti.composerWillResetConversation")
    static let rtiComposerDidFinishResume = Notification.Name("rti.composerDidFinishResume")
}


@Observable @MainActor
final class LLMController {
    struct ReferencedDocument: Equatable {
        let path: String
        let content: String
        /// The extractor's record, when there is one. Its sections carry
        /// location, so `DocumentContext` can select the passages a question
        /// actually needs instead of pasting the whole document.
        var document: ExtractedDocument? = nil
        /// The exact bytes and facts this source was handed over with. Present
        /// for a document attached from disk, an `@` vault mention, or a
        /// screenshot; nil for a source rehydrated from a plain text record.
        /// Persistence reads this and never the path.
        var payload: ChatSourcePayload? = nil
    }

    static let shared = LLMController()

    var entries: [ChatEntry] = []
    var streaming = false
    var reasoning = false
    var lastError: String?
    var lastErrorIsAuth: Bool = false
    var pendingScreenContext: String?
    /// The screenshot behind `pendingScreenContext`, when the capture produced
    /// one. Sent to the model as an image only when the active provider
    /// accepts images; otherwise the OCR text carries the turn.
    var pendingScreenImage: Data?
    /// A ready-to-draw preview of `pendingScreenImage`, so the composer's
    /// screenshot chip can show the actual capture without decoding the JPEG on
    /// every render.
    var pendingScreenPreview: NSImage?
    var screenCaptureStatus: String?
    var screenAttachmentRequestID: UUID?
    /// The question a provider error belongs to: the thread draws the error
    /// under it with Retry. Nil when `lastError` belongs to no turn (a
    /// missing file, no transcript yet, a screen permission).
    var lastErrorTurnID: UUID?
    /// Local work before an answer starts (the vault search ahead of an Ask,
    /// `/search`): the placeholder assistant entry's id and the status the
    /// thread draws in its place. The entry's own text is left as it was.
    var progressStatus: [UUID: String] = [:]
    /// Human-readable status shown beneath the streaming assistant entry
    /// while a tool is running (e.g. "📷 Looking at your screen…"). Nil
    /// when idle or when only content tokens are streaming.
    var toolStatus: String?
    var smartMode: Bool {
        didSet {
            UserDefaults.standard.set(smartMode, forKey: LLMSettingsDefaults.smartModeKey)
            // Smart mode is the app-level reasoning default; this chat's
            // reasoning follows it so the visible control and the frozen route
            // can never disagree.
            let mode: ChatReasoningMode = smartMode ? .thinking : .fast
            if chatSelection.reasoning != mode { chatSelection.reasoning = mode }
        }
    }

    /// This chat's model choice. It starts at the app default; a change here
    /// affects the current chat only, and `/new` returns it to the default.
    var chatSelection: ChatModelSelection

    /// The Broader Search row in the Add Context pane (the composer's own
    /// source and route bar was deleted 2026-09-23). Off keeps a turn that
    /// carries attached sources source-first: no vault search, and the
    /// discovery tools are not even offered. On restores ordinary discovery.
    var broaderSearchEnabled: Bool = false

    /// Which assistant action ⌘⏎ fires, by `AssistantAction.id`. Remappable per
    /// meeting; persisted. Defaults to "assist". (Was a `PrimaryAction` enum;
    /// the id strings are the same, so the stored value is compatible.)
    var primaryActionID: String {
        didSet { UserDefaults.standard.set(primaryActionID, forKey: LLMSettingsDefaults.primaryActionKey) }
    }

    var recapDepth: RecapDepth {
        didSet { UserDefaults.standard.set(recapDepth.rawValue, forKey: LLMSettingsDefaults.recapDepthKey) }
    }

    /// Passive-listener sessions: the user is observing the meeting, not
    /// speaking. Swaps the moderator-voiced quick actions ("what should I say
    /// next") for observer ones ("what's notable, what could I pass along").
    var listenerMode: Bool {
        didSet { UserDefaults.standard.set(listenerMode, forKey: LLMSettingsDefaults.listenerModeKey) }
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
        let name = (modeStore.activeMode?.name ?? "").lowercased()
        let fieldwork = ["interview", "observ", "fgd", "idi", "fieldwork", "listen"]
            .contains { name.contains($0) }
        if !fieldwork { listenerMode = false }
    }

    let request: LLMRequest
    var streamingEntryID: UUID?
    /// The whole send, from persistence through the last tool round. `cancel()`
    /// cancels this, so a `/new` during a multi-round turn stops the next
    /// round's provider call and tools too, not just the current stream.
    var sendTask: Task<Void, Never>?
#if DEBUG
    /// Captures the exact in-flight send so a storage-race proof can await it.
    var activeSendForProof: Task<Void, Never>? { sendTask }
#endif

    /// The injected store, when a test supplied one. `storeIsInjected` makes a
    /// nil store mean "no vault" rather than "fall back to the shared store".
    let injectedStore: ChatThreadStore?
    let storeIsInjected: Bool
    /// Deterministic storage delay/failure injection. Nil in the running app.
    let beforeSubmissionPersistence: (@Sendable () async throws -> Void)?
    /// Where the current recording's session id comes from. Nil uses the live
    /// coordinator.
    let sessionIDProvider: (@MainActor () -> String?)?
    /// A test's route resolver. Nil means the real registry resolution.
    let routeResolver: (@MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker>)?
    /// A test's tool executor factory. Nil uses RTI's production registry.
    let makeToolExecutor: (@MainActor (Bool, Bool) -> ToolExecutor)?
    /// Where a completed turn is logged. Nil means the vault turn log.
    let turnLogger: ((VaultLogStore.TurnRecord) -> Void)?
    /// Where this turn's ambient screen trail comes from. Nil reads the live
    /// recording and its trail; a test injects a synthetic reading so the
    /// composer's label and the request's screen block can be pinned without a
    /// capture. Never starts or touches a recording.
    let ambientScreenProvider: (@MainActor () -> String?)?
    /// A test's or render proof's mode store. Nil falls back LAZILY to the
    /// shared store on first use, so a controller with an injected store never
    /// initializes the live one.
    @ObservationIgnored private var injectedModeStore: ModeStore?
    @ObservationIgnored private var resolvedModeStore: ModeStore?

    /// The mode store this controller reads, resolved lazily. The shared store
    /// is touched only when no store was injected and one is actually needed.
    var modeStore: ModeStore {
        if let injectedModeStore { return injectedModeStore }
        if let resolvedModeStore { return resolvedModeStore }
        let store = ModeStore.shared
        resolvedModeStore = store
        return store
    }

    /// Render-proof/test seam: point the SHARED controller at an in-memory mode
    /// store before any view or route preview reads it. Never called in
    /// production.
    func useInMemoryModeStore() {
        let store = ModeStore.inMemory()
        injectedModeStore = store
        resolvedModeStore = store
    }
    /// Increments whenever the live chat's identity changes. A send captures
    /// it and refuses to install a result into a chat it no longer owns.
    var generation: Int = 0
    /// Only the latest requested conversation may adopt async history reads.
    @ObservationIgnored var resumeRequestID: UUID?
    /// The turn this send regenerates, when it is a regenerate. Consumed once
    /// by the next `performSend` and recorded on the new turn's receipt.
    var regenerationParentTurnID: String?
    /// A dated legacy log (or one entry) handed over from the Chats library.
    /// Attached to the next turn's sources as an exact recorded snapshot; it
    /// is not a saved conversation and nothing is re-read from its path.
    var pendingDatedSources: [ReferencedDocument] = []

    /// Read-only composer label for the exact dated source awaiting Send.
    var pendingDatedSourceName: String? {
        guard let source = pendingDatedSources.first else { return nil }
        return source.document?.name ?? (source.path as NSString).lastPathComponent
    }

    /// Clear a dated source only when the turn that carried it committed.
    /// A failure or a blocked route leaves it in place, so the chip and the
    /// editable prompt survive to the next attempt.
    func clearDatedSources(_ consumed: [ReferencedDocument]) {
        guard !consumed.isEmpty, pendingDatedSources == consumed else { return }
        pendingDatedSources = []
    }

    /// How many images the retained archive would send on a turn that chooses
    /// it, so the composer's preview route counts exactly the images the turn
    /// will.
    var retainedImageCount: Int {
        retainedSources.compactMap(\.payload).filter { $0.normalizedImage?.isEmpty == false }.count
    }

    /// The one identity a source is deduplicated by on the wire, so the
    /// composer's preview and the send count the same source once. A tray
    /// attachment has no payload in the composer, so its display path stands in
    /// for the id its reference will carry.
    nonisolated static func wireSourceID(path: String?, fallback: String) -> String {
        path ?? fallback
    }

    static func sourceID(_ ref: ReferencedDocument) -> String {
        wireSourceID(path: ref.payload?.path, fallback: ref.path)
    }

    /// One reference per source id, first occurrence kept (fresh-first order).
    static func deduped(_ references: [ReferencedDocument]) -> [ReferencedDocument] {
        var seen = Set<String>()
        var out: [ReferencedDocument] = []
        for ref in references {
            if seen.insert(sourceID(ref)).inserted { out.append(ref) }
        }
        return out
    }

    /// The image count the turn would actually carry, resolved with the SAME
    /// policy, the SAME fresh-vs-retained choice and the SAME dedup the send
    /// uses. The composer calls this so the preview route and the frozen route
    /// agree: a fresh-source turn never counts (or sends) the retained old
    /// images, and a source reattached in a comparison is counted once because
    /// the wire sends it once.
    ///
    /// `freshSourceIDs` and `freshImageIDs` are the wire ids of the composer's
    /// own sources (tray chips, `@` mentions) and of those that carry an image.
    /// The dated hand-over and the retained archive come from this controller.
    func chosenImageCount(
        question: String,
        freshSourceIDs: [String],
        freshImageIDs: [String],
        screenImageCount: Int
    ) -> Int {
        let (wire, freshIDs) = previewWire(question: question, freshSourceIDs: freshSourceIDs)
        let freshImages = Set(freshImageIDs).intersection(freshIDs)
        let retainedImageIDs = retainedSources.compactMap { ref -> String? in
            guard ref.payload?.normalizedImage?.isEmpty == false else { return nil }
            return Self.sourceID(ref)
        }
        let referenceImages: Int
        switch wire.choice {
        case .none:
            referenceImages = 0
        case .fresh:
            referenceImages = freshImages.count
        case .retained:
            referenceImages = retainedImageCount
        case .freshAndRetained:
            // The wire keeps the fresh copy and drops a retained source with the
            // same id, so its image is not retransmitted. Counting both would
            // promise the model two images and send one.
            referenceImages = freshImages.count + retainedImageIDs.filter { !freshIDs.contains($0) }.count
        }
        return referenceImages + screenImageCount
    }

    /// The durable thread for this chat, under the vault's
    /// `personal/rti/chats/threads`. Nil until a submitted turn is saved.
    /// An unavailable archive blocks Send and keeps the draft.
    var chatThread: ConversationRecord?
    var currentConversationID: String? { chatThread?.id }
    var threadStore: ChatThreadStore?
    /// The sources this thread was sent, rehydrated from the store's own bytes.
    /// A follow-up reads these, so a moved or deleted original does not break
    /// the chat and nothing is ever refetched.
    var retainedSources: [ReferencedDocument] = []
    /// Any notice about a retained source that could not be rehydrated.
    var retainedSourceNotice: String?
    /// The periodic partial-answer writer for the turn in flight. Process
    /// death then leaves a recoverable record instead of nothing.
    var checkpointTask: Task<Void, Never>?
    static let checkpointIntervalNanoseconds: UInt64 = 10 * 1_000_000_000

    /// A question that could not be saved. The composer puts it back in the
    /// field so a failed send never loses what the user typed.
    var pendingDraftRestore: String?

    /// The last vault answer's state, in words: a real no-match or an
    /// unavailable scan. Nil when no retrieval has run. Shown as-is so
    /// "nothing matched" never reads like "the scan is broken".
    var retrievalDiagnostic: String?

    func clearPendingDraftRestore() {
        pendingDraftRestore = nil
    }
    /// Metadata for the in-flight turn, written to the vault turn log on
    /// successful completion (see VaultLogStore).
    var pendingTurn: PendingTurn?

    struct PendingTurn {
        let id: UUID
        let ts: String
        let startedAt: Date
        let action: String
        let mode: String?
        /// The frozen route: provider, model, reasoning, and whether images
        /// may leave the Mac. Captured once at send time.
        let route: ChatRouteConfiguration
        /// Which discovery lanes this turn was allowed to use.
        let toolPolicy: ChatToolPolicy
        let inSession: Bool
        let contextUsed: Bool
        let screenUsed: Bool
        let userInput: String
        let transcriptContext: String
        var firstTokenAt: Date?
        var toolElapsedMS: Int
        var toolCount: Int
        var toolCalls: [ToolCallTrace]
        var sources: [String]
        /// The retrieval decision this turn was answered under, when there was
        /// one. Stored in the receipt.
        let decision: ContextDecision?
        /// Which of the four vault states answered this turn, when a vault
        /// search ran. Stored in the receipt and shown as a diagnostic.
        let retrievalStatus: VaultRetrieval.Status?
        /// The passage labels the answer was allowed to read, so a receipt can
        /// show what was actually selected.
        let sourceCitations: [String]
        /// The thread this turn commits to. Captured once the submitted turn
        /// is on disk, so a terminal or checkpoint write targets that chat even
        /// after `/new` or a resume replaced the live one.
        var conversationID: String?
        /// The chat generation this turn was sent under.
        let generation: Int
        /// When the source selection finished and persistence began, for the
        /// measured preparation and persistence timings.
        let preparedAt: Date
        /// When the user's send was enqueued (before preparation). Nil for a
        /// send that did not measure it, so no fake ~0 appears.
        let enqueuedAt: Date?
        /// When the submitted turn finished committing.
        var persistedAt: Date?
        /// The recording this turn belongs to, recorded on the turn itself.
        let sessionLinks: [SessionLink]
        /// The turn this one regenerates, when it is a regenerate.
        let parentTurnID: String?
        /// The vault search's own duration, when one ran.
        let retrievalSeconds: Double?
    }

    /// One tool call this turn made, with everything both the legacy turn log
    /// and the shared schema need: the round it ran in, what it asked, what
    /// came back, and how long it took.
    struct ToolCallTrace: Sendable, Equatable {
        let round: Int
        let id: String
        let name: String
        let arguments: String
        let elapsedMS: Int
        let resultCharacters: Int
        /// How the call actually ended: succeeded, failed, refused. Never a
        /// hardcoded success.
        var status: ToolRoundStatus = .succeeded
        /// The failure text when one exists.
        var error: String? = nil

        private var legacyStatus: String {
            switch status {
            case .succeeded: "ok"
            default: status.rawValue
            }
        }

        var legacyRecord: VaultLogStore.TurnRecord.ToolCall {
            VaultLogStore.TurnRecord.ToolCall(
                name: name,
                arguments: arguments,
                status: legacyStatus,
                elapsedMS: elapsedMS,
                resultCharacters: resultCharacters
            )
        }

        var schemaCall: ToolCall {
            ToolCall(
                id: id,
                name: name,
                arguments: arguments,
                resultSummary: error ?? "\(resultCharacters) characters",
                status: status,
                durationSeconds: Double(elapsedMS) / 1000,
                error: error
            )
        }
    }

    static let iso8601 = ISO8601DateFormatter()

    static let contextWindowSeconds: Double = 900

    /// Quick recap's window: the last five minutes of transcript, the
    /// "what just happened / catch me up" turn. Distinct from the sticky
    /// `recapDepth`, which only picks how many bullets a full Recap writes.
    static let quickRecapWindowSeconds: Double = 300

    /// Per-attachment ceiling for extracted text handed to the model, and the
    /// ceiling across all attachments in one request. The model's own budget
    /// is applied later by the prompt builder.
    static let attachmentCharacterBudget = 200_000
    static let attachmentTotalBudgetCharacters = 400_000

#if DEBUG
    /// Debug-only seam for the offscreen render proof (`RTIRenderTests`).
    /// Never compiled into a Release build and never called by the app.
    func seedForRenderProof(entries: [ChatEntry]) {
        self.entries = entries
        self.streaming = false
        self.lastError = nil
    }
#endif

    init(
        request: LLMRequest = LLMRequest(),
        chatStore: ChatThreadStore? = nil,
        storeIsInjected: Bool = false,
        sessionIDProvider: (@MainActor () -> String?)? = nil,
        routeResolver: (@MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker>)? = nil,
        makeToolExecutor: (@MainActor (Bool, Bool) -> ToolExecutor)? = nil,
        modeStore: ModeStore? = nil,
        turnLogger: ((VaultLogStore.TurnRecord) -> Void)? = nil,
        ambientScreenProvider: (@MainActor () -> String?)? = nil,
        beforeSubmissionPersistence: (@Sendable () async throws -> Void)? = nil
    ) {
        self.request = request
        self.injectedStore = chatStore
        self.storeIsInjected = storeIsInjected
        self.beforeSubmissionPersistence = beforeSubmissionPersistence
        self.sessionIDProvider = sessionIDProvider
        self.routeResolver = routeResolver
        self.makeToolExecutor = makeToolExecutor
        self.injectedModeStore = modeStore
        self.turnLogger = turnLogger
        self.ambientScreenProvider = ambientScreenProvider
        let smartDefault = UserDefaults.standard.bool(forKey: LLMSettingsDefaults.smartModeKey)
        smartMode = smartDefault
        chatSelection = ChatModelSelection(
            providerId: LLMProviders.activeId,
            reasoning: smartDefault ? .thinking : .fast
        )
        // The shipped primary action is Quick recap. An explicit user choice
        // wins; the one-time migration below only moves the old defaults
        // (Assist / Answer latest) that predate it.
        let storedPrimary = UserDefaults.standard.string(forKey: LLMSettingsDefaults.primaryActionKey)
        let alreadyMigrated = UserDefaults.standard.bool(forKey: LLMSettingsDefaults.primaryQuickRecapMigrationKey)
        let resolvedPrimary = PrimaryActionMigration.resolve(stored: storedPrimary, alreadyMigrated: alreadyMigrated)
        if !alreadyMigrated {
            // Mark the migration run on EVERY first-run path, not only when it
            // changes something: a stored value outside the old defaults must
            // not leave the flag unset, or a later deliberate bind to Assist /
            // Answer latest would be silently reverted on the next launch.
            UserDefaults.standard.set(true, forKey: LLMSettingsDefaults.primaryQuickRecapMigrationKey)
            // `didSet` does not fire for the assignment below (we are still in
            // `init`), so persist a changed value explicitly.
            if resolvedPrimary != storedPrimary {
                UserDefaults.standard.set(resolvedPrimary, forKey: LLMSettingsDefaults.primaryActionKey)
            }
        }
        primaryActionID = resolvedPrimary
        listenerMode = UserDefaults.standard.bool(forKey: LLMSettingsDefaults.listenerModeKey)
        recapDepth = RecapDepth(rawValue: UserDefaults.standard.string(forKey: LLMSettingsDefaults.recapDepthKey) ?? "") ?? .standard
    }
}
