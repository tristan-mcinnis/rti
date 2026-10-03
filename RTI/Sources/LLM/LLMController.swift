import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

/// The exact bytes and facts behind one source a turn was handed.
///
/// Built once at send time from the typed attachment or the captured
/// screenshot. Persistence reads this and never re-reads a path, so one
/// attachment's bytes can never be substituted for another's.
struct ChatSourcePayload: Sendable, Equatable {
    var name: String
    /// The chip kind this source is shown as.
    var displayKind: ChatAttachmentRef.Kind
    /// The archive kind, from the extractor's own record.
    var archiveKind: AttachmentKind
    var path: String?
    var byteCount: Int?
    var pageCount: Int?
    var wasCut: Bool
    var originalBytes: Data?
    var originalExtension: String?
    var normalizedImage: Data?
    var normalizedImageExtension: String?
    /// The mime type of `normalizedImage`, so a wire `LLMImage` carries the
    /// exact bytes with the right label.
    var normalizedImageMimeType: String?
    var extractedText: String?
    var document: ExtractedDocument?

    init(from attachment: ExternalDocumentAttachment) {
        self.name = attachment.name
        self.displayKind = attachment.kind
        self.archiveKind = attachment.document.kind
        self.path = attachment.path
        self.byteCount = attachment.byteCount
        self.pageCount = attachment.pageCount
        self.wasCut = attachment.wasCut
        self.originalBytes = attachment.originalBytes.isEmpty ? nil : attachment.originalBytes
        self.originalExtension = attachment.path.map { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.normalizedImage = attachment.normalizedImage?.data
        self.normalizedImageExtension = Self.fileExtension(forMime: attachment.normalizedImage?.mimeType)
        self.normalizedImageMimeType = attachment.normalizedImage?.mimeType
        self.extractedText = attachment.text
        self.document = attachment.document
    }

    init(screenJPEG: Data?, ocrText: String?) {
        self.name = "Screenshot"
        self.displayKind = .screen
        self.archiveKind = .screenshot
        self.path = nil
        self.byteCount = screenJPEG?.count
        self.pageCount = nil
        self.wasCut = false
        self.originalBytes = screenJPEG
        self.originalExtension = screenJPEG == nil ? nil : "jpg"
        self.normalizedImage = screenJPEG
        self.normalizedImageExtension = screenJPEG == nil ? nil : "jpg"
        self.normalizedImageMimeType = screenJPEG == nil ? nil : "image/jpeg"
        self.extractedText = ocrText
        self.document = nil
    }

    /// A source read back from the store for a follow-up. Its bytes come from
    /// the store, never from a path, so a moved or deleted original does not
    /// change what the follow-up is answered from.
    init(retained name: String, kind: AttachmentKind, path: String?, originalBytes: Data?, normalizedImage: Data?, normalizedImageMimeType: String?, extractedText: String?, document: ExtractedDocument?) {
        self.name = name
        self.displayKind = Self.displayKind(for: kind)
        self.archiveKind = kind
        self.path = path
        self.byteCount = originalBytes?.count
        self.pageCount = document?.sectionUnit == .page ? document?.unitCount : nil
        self.wasCut = document?.truncation != nil
        self.originalBytes = originalBytes
        self.originalExtension = Self.fileExtension(forKind: kind, name: name)
        self.normalizedImage = normalizedImage
        self.normalizedImageExtension = Self.fileExtension(forMime: normalizedImageMimeType)
        self.normalizedImageMimeType = normalizedImageMimeType
        self.extractedText = extractedText ?? document?.text
        self.document = document
    }

    static func displayKind(for kind: AttachmentKind) -> ChatAttachmentRef.Kind {
        switch kind {
        case .pdf: .pdf
        case .image: .image
        case .screenshot: .screen
        case .text, .markdown, .code, .html: .text
        default: .vaultFile
        }
    }

    private static func fileExtension(forKind kind: AttachmentKind, name: String) -> String? {
        let ext = URL(fileURLWithPath: name).pathExtension
        if !ext.isEmpty { return ext }
        return kind == .pdf ? "pdf" : nil
    }

    /// A dated legacy log handed over from the Chats library. The recorded
    /// text is the source; the log path stays a metadata-only reference.
    init(dated name: String, sourcePath: String?, text: String, document: ExtractedDocument?) {
        self.name = name
        self.displayKind = .text
        self.archiveKind = .markdown
        self.path = sourcePath
        self.byteCount = text.utf8.count
        self.pageCount = nil
        self.wasCut = false
        self.originalBytes = text.data(using: .utf8)
        self.originalExtension = "txt"
        self.normalizedImage = nil
        self.normalizedImageExtension = nil
        self.normalizedImageMimeType = nil
        self.extractedText = text
        self.document = document
    }

    /// A mention of a vault file: text plus the file's own bytes, when they
    /// were read at hand-over time. Never re-read later.
    init(name: String, path: String, text: String, bytes: Data?, document: ExtractedDocument?, wasCut: Bool = false) {
        self.name = name
        self.displayKind = .vaultFile
        self.archiveKind = .markdown
        self.path = path
        self.byteCount = bytes?.count
        self.pageCount = nil
        self.wasCut = wasCut
        self.originalBytes = bytes
        self.originalExtension = URL(fileURLWithPath: path).pathExtension.isEmpty
            ? nil : URL(fileURLWithPath: path).pathExtension
        self.normalizedImage = nil
        self.normalizedImageExtension = nil
        self.normalizedImageMimeType = nil
        self.extractedText = text
        self.document = document
    }

    /// The record the store commits for this source.
    var submitted: ChatThreadStore.SubmittedAttachment {
        ChatThreadStore.SubmittedAttachment(
            kind: archiveKind,
            name: name,
            path: path,
            byteCount: byteCount,
            pageCount: pageCount,
            originalBytes: originalBytes,
            originalExtension: originalExtension,
            normalizedImage: normalizedImage,
            normalizedImageExtension: normalizedImageExtension,
            extractedText: extractedText,
            extractedDocument: document,
            wasCut: wasCut
        )
    }

    private static func fileExtension(forMime mime: String?) -> String? {
        switch mime {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/heic": "heic"
        default: mime?.split(separator: "/").last.map(String.init)
        }
    }
}

@Observable @MainActor
final class LLMController {
    private struct ReferencedDocument: Equatable {
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

    private(set) var entries: [ChatEntry] = []
    private(set) var streaming = false
    private(set) var reasoning = false
    private(set) var lastError: String?
    private(set) var lastErrorIsAuth: Bool = false
    private(set) var pendingScreenContext: String?
    /// The screenshot behind `pendingScreenContext`, when the capture produced
    /// one. Sent to the model as an image only when the active provider
    /// accepts images; otherwise the OCR text carries the turn.
    private(set) var pendingScreenImage: Data?
    /// A ready-to-draw preview of `pendingScreenImage`, so the composer's
    /// screenshot chip can show the actual capture without decoding the JPEG on
    /// every render.
    private(set) var pendingScreenPreview: NSImage?
    private(set) var screenCaptureStatus: String?
    private var screenAttachmentRequestID: UUID?
    /// The question a provider error belongs to: the thread draws the error
    /// under it with Retry. Nil when `lastError` belongs to no turn (a
    /// missing file, no transcript yet, a screen permission).
    private(set) var lastErrorTurnID: UUID?
    /// Local work before an answer starts (the vault search ahead of an Ask,
    /// `/search`): the placeholder assistant entry's id and the status the
    /// thread draws in its place. The entry's own text is left as it was.
    private(set) var progressStatus: [UUID: String] = [:]
    /// Human-readable status shown beneath the streaming assistant entry
    /// while a tool is running (e.g. "📷 Looking at your screen…"). Nil
    /// when idle or when only content tokens are streaming.
    private(set) var toolStatus: String?
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

    private let request: LLMRequest
    private var streamingEntryID: UUID?
    /// The whole send, from persistence through the last tool round. `cancel()`
    /// cancels this, so a `/new` during a multi-round turn stops the next
    /// round's provider call and tools too, not just the current stream.
    private var sendTask: Task<Void, Never>?

    /// The injected store, when a test supplied one. `storeIsInjected` makes a
    /// nil store mean "no vault" rather than "fall back to the shared store".
    private let injectedStore: ChatThreadStore?
    private let storeIsInjected: Bool
    /// Where the current recording's session id comes from. Nil uses the live
    /// coordinator.
    private let sessionIDProvider: (@MainActor () -> String?)?
    /// A test's route resolver. Nil means the real registry resolution.
    private let routeResolver: (@MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker>)?
    /// A test's tool executor factory. Nil uses RTI's production registry.
    private let makeToolExecutor: (@MainActor (Bool, Bool) -> ToolExecutor)?
    /// Where a completed turn is logged. Nil means the vault turn log.
    private let turnLogger: ((VaultLogStore.TurnRecord) -> Void)?
    /// A test's or render proof's mode store. Nil falls back LAZILY to the
    /// shared store on first use, so a controller with an injected store never
    /// initializes the live one.
    @ObservationIgnored private var injectedModeStore: ModeStore?
    @ObservationIgnored private var resolvedModeStore: ModeStore?

    /// The mode store this controller reads, resolved lazily. The shared store
    /// is touched only when no store was injected and one is actually needed.
    private var modeStore: ModeStore {
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
    private var generation: Int = 0
    /// The turn this send regenerates, when it is a regenerate. Consumed once
    /// by the next `performSend` and recorded on the new turn's receipt.
    private var regenerationParentTurnID: String?
    /// A dated legacy log (or one entry) handed over from the Chats library.
    /// Attached to the next turn's sources as an exact recorded snapshot; it
    /// is not a saved conversation and nothing is re-read from its path.
    private var pendingDatedSources: [ReferencedDocument] = []

    /// Read-only composer label for the exact dated source awaiting Send.
    var pendingDatedSourceName: String? {
        guard let source = pendingDatedSources.first else { return nil }
        return source.document?.name ?? (source.path as NSString).lastPathComponent
    }

    /// Clear a dated source only when the turn that carried it committed.
    /// A failure or a blocked route leaves it in place, so the chip and the
    /// editable prompt survive to the next attempt.
    private func clearDatedSources(_ consumed: [ReferencedDocument]) {
        guard !consumed.isEmpty, pendingDatedSources == consumed else { return }
        pendingDatedSources = []
    }

    /// How many images the retained archive would send on a turn that chooses
    /// it, so the composer's preview route counts exactly the images the turn
    /// will.
    var retainedImageCount: Int {
        retainedSources.compactMap(\.payload).filter { $0.normalizedImage?.isEmpty == false }.count
    }

    /// One reference per source id, first occurrence kept (fresh-first order).
    private static func deduped(_ references: [ReferencedDocument]) -> [ReferencedDocument] {
        var seen = Set<String>()
        var out: [ReferencedDocument] = []
        for ref in references {
            let id = ref.payload?.path ?? ref.path
            if seen.insert(id).inserted { out.append(ref) }
        }
        return out
    }

    /// The image count the turn would actually carry, resolved with the SAME
    /// policy and the SAME fresh-vs-retained choice the send uses. The
    /// composer calls this so the preview route and the frozen route agree:
    /// a fresh-source turn never counts (or sends) the retained old images.
    func chosenImageCount(
        question: String,
        freshSourceCount: Int,
        freshImageCount: Int,
        screenImageCount: Int
    ) -> Int {
        let decision = ContextPolicy.standard.resolve(ChatContextRequestBuilder.request(
            question: question,
            currentSourceCount: freshSourceCount,
            historyTurnCount: entries.filter { $0.role == "user" }.count,
            historyHasSources: entries.contains { $0.role == "user" && !$0.attachments.isEmpty },
            broaderToggleOn: broaderSearchEnabled
        ))
        let referenceImages: Int
        if freshSourceCount == 0 {
            referenceImages = retainedImageCount
        } else if decision.includesHistory {
            referenceImages = freshImageCount + retainedImageCount
        } else {
            referenceImages = freshImageCount
        }
        return referenceImages + screenImageCount
    }

    /// The durable thread for this chat, under the vault's
    /// `personal/rti/chats/threads`. Nil until a submitted turn is saved.
    /// An unavailable archive blocks Send and keeps the draft.
    private var chatThread: ConversationRecord?
    private var threadStore: ChatThreadStore?
    /// The sources this thread was sent, rehydrated from the store's own bytes.
    /// A follow-up reads these, so a moved or deleted original does not break
    /// the chat and nothing is ever refetched.
    private var retainedSources: [ReferencedDocument] = []
    /// Any notice about a retained source that could not be rehydrated.
    private(set) var retainedSourceNotice: String?
    /// The periodic partial-answer writer for the turn in flight. Process
    /// death then leaves a recoverable record instead of nothing.
    private var checkpointTask: Task<Void, Never>?
    static let checkpointIntervalNanoseconds: UInt64 = 10 * 1_000_000_000

    /// A question that could not be saved. The composer puts it back in the
    /// field so a failed send never loses what the user typed.
    private(set) var pendingDraftRestore: String?

    /// The last vault answer's state, in words: a real no-match, a degraded
    /// answer from the keyword fallback, or an unavailable index. Nil when no
    /// retrieval has run. Shown as-is so "nothing matched" never reads like
    /// "the index is broken".
    private(set) var retrievalDiagnostic: String?

    func clearPendingDraftRestore() {
        pendingDraftRestore = nil
    }
    /// Metadata for the in-flight turn, written to the vault turn log on
    /// successful completion (see VaultLogStore).
    private var pendingTurn: PendingTurn?

    private struct PendingTurn {
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

    private static let iso8601 = ISO8601DateFormatter()

    private static let contextWindowSeconds: Double = 900

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
        turnLogger: ((VaultLogStore.TurnRecord) -> Void)? = nil
    ) {
        self.request = request
        self.injectedStore = chatStore
        self.storeIsInjected = storeIsInjected
        self.sessionIDProvider = sessionIDProvider
        self.routeResolver = routeResolver
        self.makeToolExecutor = makeToolExecutor
        self.injectedModeStore = modeStore
        self.turnLogger = turnLogger
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
        let kind = modeStore.activeMode?.kind ?? .other
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
        // The policy resolves on THIS TURN's sources, so a fresh source is
        // source-first. Retained history is admitted only when the question
        // asks for it, or when there is no fresh source at all. This is
        // resolved BEFORE the wire set is composed, so the receipt and the
        // wire can never disagree.
        let decision = ContextPolicy.standard.resolve(ChatContextRequestBuilder.request(
            question: userInput,
            currentSourceCount: freshReferences.count,
            historyTurnCount: entries.filter { $0.role == "user" }.count,
            historyHasSources: entries.contains { $0.role == "user" && !$0.attachments.isEmpty },
            broaderToggleOn: broaderSearchEnabled
        ))
        // The wire set: a follow-up with nothing new reads the retained
        // archive; a fresh source is answered from itself unless the question
        // explicitly asks to include earlier turns. Fresh first for budget, and
        // an old image is never retransmitted on a fresh-source-scope turn.
        let sentReferences: [ReferencedDocument]
        if freshReferences.isEmpty {
            sentReferences = retainedSources
        } else if decision.includesHistory {
            sentReferences = Self.deduped(freshReferences + retainedSources)
        } else {
            sentReferences = freshReferences
        }
        prepared.references = sentReferences
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
                enqueuedAt: enqueuedAt,
                consumedDatedSources: datedSources,
                toolPolicy: toolPolicy,
                decision: decision
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
            performSend(
                userInput: userInput,
                action: "Ask",
                referencedDocuments: prepared.references,
                attachments: Self.attachmentRefs(references: prepared.references),
                sourcePayloads: freshPayloads,
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

    /// Copy Response: the newest answer, as Markdown. False when there is none.
    @discardableResult
    func copyLatestAnswer() -> Bool {
        guard let answer = latestAnswer else { return false }
        NSPasteboard.copyString(answer.text)
        return true
    }

    /// Copy Sources: the newest answer's source paths, one a line. False
    /// when it cited none.
    @discardableResult
    func copyLatestSources() -> Bool {
        guard let sources = latestAnswer?.sources, !sources.isEmpty else { return false }
        NSPasteboard.copyString(ChatTurnRecordBuilder.sourcesText(sources))
        return true
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
        if let requestID, !isCurrentScreenAttachment(requestID) { return }
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
        if let requestID, !isCurrentScreenAttachment(requestID) { return }
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
        if let requestID, !isCurrentScreenAttachment(requestID) { return }
        screenCaptureStatus = message
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        request.cancel()
        stopCheckpointing()
        streaming = false
        reasoning = false
        toolStatus = nil
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
        // A stopped answer is a turn too, with status cancelled, so the
        // question is never left in the thread without its outcome.
        let stopped = pendingTurn
        pendingTurn = nil
        if let stopped {
            Task { await self.persistTurnResult(stopped, text: "", status: .cancelled, error: nil) }
        }
    }

    /// Cancel any in-flight stream and drop the in-memory entries without
    /// touching persisted chat_messages.
    func resetMemory() {
        cancel()
        clearPendingScreenContext()
        entries = []
        progressStatus = [:]
        lastError = nil
        lastErrorIsAuth = false
        lastErrorTurnID = nil
        // The chat's identity changed: an in-flight send may no longer write
        // into it or start a provider call on its behalf.
        generation &+= 1
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
        if plan.cancelsStream { cancel() }
        resetMemory()
        if plan.resetsModelSelection {
            chatSelection = ChatModelSelection(
                providerId: LLMProviders.activeId,
                reasoning: smartMode ? .thinking : .fast
            )
        }
        if plan.resetsBroaderSearch { broaderSearchEnabled = false }
        pendingDatedSources = []
        // A new chat is a new thread: the one just used stays on disk, and the
        // recording is untouched.
        if plan.preservesSavedThread { chatThread = nil }
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
    private func currentSessionID() -> String? {
        if let sessionIDProvider { return sessionIDProvider() }
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
    private func chatStore() throws -> ChatThreadStore? {
        // An injected store (a test) is used as-is: nil then means "no vault",
        // never a fall back to the live one.
        if storeIsInjected { return injectedStore }
        if let threadStore { return threadStore }
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
        guard let store = try chatStore() else { return nil }
        guard store.contains(id: id) else { return nil }
        let thread = try await store.load(id: id)
        chatThread = thread
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
            // A turn a process death left mid-answer becomes a cancelled turn
            // before anything is shown, so the chat tells the truth.
            let marked = try await store.markInterrupted(id: id)
            if marked > 0 {
                RTILog.log("marked \(marked) interrupted turn(s) in \(id)", category: .llm)
            }
            let thread = try await store.load(id: id)
            let retained = try await store.retainedAttachments(id: id)

            cancel()
            resetMemory()
            chatThread = thread
            entries = Self.entries(from: thread)
            retainedSources = retained.map(Self.referencedDocument(from:))
            retainedSourceNotice = Self.missingNotice(retained)
            chatSelection = Self.selection(from: thread, fallback: chatSelection)
            broaderSearchEnabled = false
            lastError = nil
            lastErrorIsAuth = false
            lastErrorTurnID = nil
        } catch {
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
            path: retained.path ?? "Attached file: \(retained.name)",
            content: retained.extractedText ?? "",
            document: retained.document,
            payload: payload
        )
    }

    /// A typed payload as a source for the next turn. Used to hydrate what a
    /// turn was just sent, so a follow-up reads the same bytes with no reread.
    private static func referencedDocument(from payload: ChatSourcePayload) -> ReferencedDocument {
        ReferencedDocument(
            path: payload.path ?? "Attached file: \(payload.name)",
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

    /// The threads a caller can list, newest first. The Chats surface uses
    /// this; the store owns the reading.
    func storedThreads() async throws -> [ConversationSummary] {
        guard let store = try chatStore() else { return [] }
        return try await store.summaries()
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
    private enum PersistOutcome {
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
    private func persistSubmittedTurn(
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
        let store: ChatThreadStore
        do {
            guard let created = try chatStore() else { return .noStore }
            store = created
        } catch {
            return .failed("Could not open the chat store: \(error.localizedDescription)")
        }

        // Every attachment's bytes come from its own typed payload. There is
        // no switch on a display kind and no path is read here.
        var submitted = sourcePayloads.map(\.submitted)
        if let screenPayload { submitted.append(screenPayload.submitted) }

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
                guard generation == self.generation else { return .aborted }
                thread = created
            }
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
            guard generation == self.generation else { return .aborted }
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
        // The vault's four states are kept apart: a genuine no-match is not a
        // degraded answer, and neither is an unavailable index.
        let matched: Bool?
        let complete: Bool?
        switch retrievalStatus {
        case .available: matched = true; complete = true
        case .noMatch: matched = false; complete = true
        case .degraded: matched = nil; complete = false
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
        if let appVersion = appVersion {
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
        case .degraded: "degraded"
        case .unavailable: "unavailable"
        }
    }

    /// The one line a surface shows for a retrieval state. A no-match is a
    /// real answer; a degradation names its cause.
    static func statusDiagnostic(_ status: VaultRetrieval.Status) -> String? {
        switch status {
        case .available:
            return nil
        case .noMatch:
            return "Vault search found nothing for that question."
        case let .degraded(reason):
            return "Vault search fell back to the keyword scan: \(reason)"
        case let .unavailable(reason):
            return "Vault search is unavailable: \(reason)"
        }
    }

    /// Group the flat call trace into one round per loop iteration, which is
    /// what the schema calls a tool round.
    private static func toolRounds(from traces: [ToolCallTrace]) -> [ToolRound] {
        var rounds: [ToolRound] = []
        for (index, round) in Set(traces.map(\.round)).sorted().enumerated() {
            let calls = traces.filter { $0.round == round }
            // A round is only a success when every call in it succeeded.
            let status: ToolRoundStatus = if calls.contains(where: { $0.status == .failed }) {
                .failed
            } else if !calls.isEmpty && calls.allSatisfy({ $0.status == .refused }) {
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
    private static func modelSelection(for route: ChatRouteConfiguration) -> ModelSelection {
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
    private static func requestSnapshot(
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
        if let decision { body["contextRationale"] = decision.rationale }
        if let encoded = try? JSONEncoder().encode(messages),
           let decoded = try? JSONSerialization.jsonObject(with: encoded) {
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

    // MARK: Composer commands

    /// What the composer should do with a line.
    enum ChatCommandOutcome: Equatable {
        /// A command ran, or a composer-owned one was recognized.
        case handled(String)
        /// No such command. It went nowhere: only an explicit Send as Text
        /// action may turn it into a message.
        case unknown(rawName: String, message: String)
        /// Ordinary prompt text.
        case notACommand
        case empty
    }

    /// Commands the composer owns (a mode switch, not a model call). The
    /// parser recognizes them so they are never mistaken for unknown, and the
    /// caller acts on the id.
    static let composerOwnedCommandIDs: Set<String> = ["note", "chat"]

    /// The commands the shared parser recognizes for RTI: RTI's own catalogue
    /// as known commands, plus its aliases. The parser's own builtins
    /// (`/new`, `/clear`) are recognized before any alias, so an alias can
    /// never shadow them.
    static var composerCommandParser: ChatCommandParser {
        var aliases: [String: String] = [:]
        for command in ComposerSlashCommand.all {
            let canonical = "/" + command.id
            for alias in command.aliases {
                aliases["/" + alias] = canonical
            }
        }
        return ChatCommandParser(
            knownCommands: Set(ComposerSlashCommand.all.map { "/" + $0.id }),
            aliases: aliases
        )
    }

    /// Parse and run a composer line.
    ///
    /// An unknown slash command is refused and shown locally. This method never
    /// sends it: the only path that turns it into a message is the caller's
    /// explicit `sendAsText(_:)`, which is what "stay local with an explicit
    /// Send as Text action" means.
    func handleComposerCommand(_ input: String) -> ChatCommandOutcome {
        switch Self.composerCommandParser.parse(input) {
        case .empty:
            return .empty
        case .notACommand:
            return .notACommand
        case let .unknown(rawName, message):
            postLocalTurn(userInput: input, action: "Command", output: message)
            return .unknown(rawName: rawName, message: message)
        case let .command(command):
            switch command.name {
            case .new, .clear:
                newChat()
                return .handled(command.name.rawValue)
            case let .known(name):
                let id = name.hasPrefix("/") ? String(name.dropFirst()) : name
                if Self.composerOwnedCommandIDs.contains(id) {
                    return .handled(id)
                }
                let argument = command.arguments.joined(separator: " ")
                guard runComposerCommand(id: id, argument: argument) else {
                    let detail = "Unknown command \(command.rawName)."
                    postLocalTurn(userInput: input, action: "Command", output: detail)
                    return .unknown(rawName: command.rawName, message: detail)
                }
                return .handled(id)
            }
        }
    }

    /// Run one RTI command by id. Returns false when no handler exists.
    @discardableResult
    func runComposerCommand(id: String, argument: String) -> Bool {
        switch id {
        case "assist": sendAssist()
        case "answer": sendAnswerLatest()
        case "say": sendSaySomething()
        case "followups": sendFollowupQuestions()
        case "recap": sendRecap()
        case "summary": sendSummary()
        case "screen": ScreenshotManager.shared.captureAndAttach()
        case "recent":
            sendAskAnything("What were the most recent meetings or sessions for this project? Use the recent meetings tool if project context is available.")
        case "search": sendVaultSearchCommand(argument)
        case "sources": sendVaultSourcesCommand(argument.isEmpty ? nil : argument)
        case "project": runProjectCommand(argument)
        case "help": showSlashHelp()
        default: return false
        }
        return true
    }

    /// The one path that turns a refused line into a message: the caller asks
    /// for it explicitly, after the local error has been shown.
    func sendAsText(_ text: String) {
        sendAskAnything(text)
    }

    // MARK: Streaming checkpoints

    /// Start writing the partial answer periodically. The terminal write
    /// replaces the same turn, so a checkpointed answer is one row.
    private func startCheckpointing(turnID: UUID) {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.checkpointIntervalNanoseconds)
                if Task.isCancelled { return }
                await self?.writeCheckpoint(turnID: turnID)
            }
        }
    }

    private func stopCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    /// One checkpoint write. Silent when there is nothing to say yet, and loud
    /// only to the log when the write fails: the answer is still streaming and
    /// the user is owed the text, not a dialog.
    private func writeCheckpoint(turnID: UUID) async {
        guard streaming, streamingEntryID == turnID,
              let pending = pendingTurn, pending.id == turnID,
              let conversationID = pending.conversationID,
              let index = entries.firstIndex(where: { $0.id == turnID })
        else { return }
        let text = entries[index].text
        guard !text.isEmpty else { return }
        do {
            guard let store = try chatStore() else { return }
            try await store.checkpoint(
                conversationID: conversationID,
                turnID: turnID.uuidString,
                text: text,
                startedAt: pending.startedAt,
                model: Self.modelSelection(for: pending.route),
                toolRounds: Self.toolRounds(from: pending.toolCalls)
            )
        } catch {
            RTILog.log("checkpoint skipped: \(error)", category: .llm)
        }
    }

    /// Freeze this turn's route from the chat's selection. The decision itself    /// is pure (`ChatRouteResolver`); this only supplies the registry entry
    /// and the vision fallback the user accepted.
    private func resolveTurnRoute(
        imageCount: Int,
        forceSmart: Bool
    ) -> Result<ChatRouteConfiguration, ChatRouteBlocker> {
        if let routeResolver {
            return routeResolver(chatSelection, imageCount, forceSmart)
        }
        let provider = LLMProviders.option(id: chatSelection.providerId).config
        var selection = chatSelection
        // RTI Summary's visible thinking override and the global smart default
        // both land here, on the per-chat selection, before it freezes.
        if forceSmart { selection.reasoning = .thinking }
        // No separate vision model ships today, so an image on a text-only
        // route degrades to text-only and is labelled. When the registry gains
        // a vision model, name it here and the thread labels the fallback.
        let options = ChatRouteOptions(
            visionModelIds: provider.supportsVision ? [provider.model] : [],
            visionFallbackModelId: nil
        )
        return ChatRouteResolver.resolve(
            selection: selection,
            provider: provider,
            options: options,
            imageCount: imageCount
        )
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
        progressStatus[assistantID] = "Searching the vault…"
        Task { @MainActor in
            let scope = Self.retrievalScope(for: trimmed)
            let retrieval = await VaultRetrieval.search(query: trimmed, scopeRelativePath: scope)
            self.retrievalDiagnostic = Self.statusDiagnostic(retrieval.status)
            let label = scope == nil ? "Vault-wide search" : "Scoped search"
            finishLocalProgress(assistantID, retrieval: retrieval, scoped: scope != nil)
            updateLocalAssistant(
                assistantID,
                text: Self.searchAnswerText(label: label, retrieval: retrieval)
            )
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
        progressStatus[assistantID] = "Finding sources…"
        Task { @MainActor in
            let scope = Self.retrievalScope(for: effective)
            let retrieval = await VaultRetrieval.search(query: effective, scopeRelativePath: scope)
            self.retrievalDiagnostic = Self.statusDiagnostic(retrieval.status)
            let label = scope == nil ? "Vault-wide sources" : "Scoped sources"
            finishLocalProgress(assistantID, retrieval: retrieval, scoped: scope != nil)
            updateLocalAssistant(
                assistantID,
                text: "**\(label) for:** \(effective)\n\n" + Self.searchAnswerText(label: label, retrieval: retrieval)
            )
        }
    }

    func runProjectCommand(_ argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let current = MeetingContextStore.shared.workstreamName.map { "Current context: **\($0)**" }
                ?? "No project/client selected. RAG defaults to the whole vault."
            let projects = VaultWorkstreamStore.projects().prefix(8).map(\.name).joined(separator: ", ")
            let clients = VaultWorkstreamStore.clients().prefix(5).map(\.name).joined(separator: ", ")
            let examples = "Use `/project acme wear`, `/project clear`, or pick one in Setup."
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
        transcriptSeconds: Double? = nil,
        forceSmart: Bool = false,
        referencedDocuments: [ReferencedDocument] = [],
        retrievalContext: String? = nil,
        initialTrace: String? = nil,
        attachments: [ChatAttachmentRef] = [],
        sourcePayloads: [ChatSourcePayload] = [],
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
        let ambientScreenContext = SessionCoordinator.shared.isRunning
            ? VisualContextTrail.shared.recentPromptContext()
            : nil
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
            images: runtimeImages,
            referencedDocumentsText: sourceSelection.text,
            existingEntries: entries
        ))

        // Turn records for the thread: what went with the question, and what
        // the answer read before the model ran. Display only.
        let ambientScreenRead = !(ambientScreenContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var sentAttachments = attachments
        if screenAttached, !sentAttachments.contains(where: { $0.kind == .screen }) {
            sentAttachments.append(ChatAttachmentRef(kind: .screen, name: "Screenshot"))
        }
        var answerTools = ChatTurnRecordBuilder.contextLines(
            transcriptMinutes: turn.contextUsed ? transcriptWindowMinutes(fullWindow: fullTranscript, maxSeconds: transcriptSeconds) : nil,
            wholeTranscript: fullTranscript,
            screenRead: screenAttached,
            screenFromTrail: ambientScreenRead
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
                self.entries.removeAll { $0.id == userEntry.id || $0.id == assistantEntry.id }
                self.streaming = false
                self.reasoning = false
                self.streamingEntryID = nil
                if self.pendingTurn?.id == thisEntryID { self.pendingTurn = nil }
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
            // A `/new` or resume that landed while the question was written
            // must not let this send proceed on the old chat's behalf.
            guard self.generation == capturedGeneration else {
                self.entries.removeAll { $0.id == userEntry.id || $0.id == assistantEntry.id }
                self.streaming = false
                self.reasoning = false
                self.streamingEntryID = nil
                if self.pendingTurn?.id == thisEntryID { self.pendingTurn = nil }
                return
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
                            self.lastError = message
                            self.lastErrorIsAuth = isAuth
                            self.streaming = false
                            self.reasoning = false
                            self.toolStatus = nil
                            self.pruneTrailingEmptyAssistant()
                            // The failed question stays; its error draws under it.
                            self.lastErrorTurnID = self.entries.last?.role == "user" ? self.entries.last?.id : nil
                            self.streamingEntryID = nil
                            self.stopCheckpointing()
                            // A failed answer is still a turn: store it with its
                            // error so the thread does not lose the question.
                            let failed = self.pendingTurn
                            self.pendingTurn = nil
                            if let failed {
                                Task { await self.persistTurnResult(failed, text: "", status: .failed, error: message) }
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
        stopCheckpointing()
        logCompletedTurn(thisEntryID)
        pruneTrailingEmptyAssistant()
        streamingEntryID = nil
        if let finished {
            Task { await self.persistTurnResult(finished, text: finalText, status: .completed, error: nil) }
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
    /// the question text ("acmewear" should hit "Acme Wear") before falling
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
        // The typed attachment travels whole: original bytes, normalized image,
        // real path, size, cut flag and the extractor's record. Nothing here
        // collapses it to a name for persistence to re-read later.
        var references = attachments.map {
            ReferencedDocument(
                path: $0.path ?? "Attached file: \($0.name)",
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

    private func postLocalTurn(userInput: String, action: String, output: String) {
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

    private func updateLocalAssistant(_ id: UUID, text: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
        if progressStatus[id] != nil { progressStatus[id] = text }
    }

    /// A local search finished: the entry stops being a status and carries
    /// the search's line and sources.
    private func finishLocalProgress(_ id: UUID, retrieval: VaultRetrieval.Response, scoped: Bool) {
        progressStatus[id] = nil
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].tools = ChatTurnRecordBuilder.appending(
            ToolTraceParser.searchLine(resultCount: retrieval.results.count, scoped: scoped),
            to: entries[idx].tools
        )
        entries[idx].sources = ChatTurnRecordBuilder.merging(Self.chatSources(retrieval), into: entries[idx].sources)
    }

    private func beginLocalProgress(userInput: String, action: String, text: String) -> UUID {
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

    private func removeLocalProgress(_ assistantID: UUID) {
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
    private static func chatSources(_ retrieval: VaultRetrieval.Response) -> [ChatSource] {
        retrieval.results.map { ChatSource(title: $0.title, path: $0.relativePath, date: $0.modified) }
    }

    /// The chips over an Ask, built from the typed sources themselves: a
    /// vault file keeps its path, a document keeps its own size and page
    /// count, and a screen capture stays a screen capture. Never rebuilt from
    /// a name or inferred from a suffix.
    private static func attachmentRefs(references: [ReferencedDocument]) -> [ChatAttachmentRef] {
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

        // Labels come from the speaker id, as in the Transcript tab, so "Speaker
        // 2" in a question and in the answer is the person the tab shows.
        let names = SpeakerNameStore.shared.names
        let formatLine: (LiveEntry) -> String = { entry in
            if entry.speakerId == "note" { return "[my note]: \(entry.text)" }
            return "\(TranscriptContext.speakerLabel(for: entry.speakerId, names: names)): \(entry.text)"
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
        let kind = modeStore.activeMode?.kind ?? .other
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
}
