import Foundation
import HouseChatCore

/// Why a thread write was refused.
public enum ChatThreadStoreError: Error, Equatable, LocalizedError {
    /// The thread was deleted. Recreating it by appending would silently
    /// undo that, so the caller has to start a new chat on purpose.
    case threadDeleted(id: String)

    /// The record and its bytes were removed, but one or more of the daily
    /// compatibility projections it owned could not be cleaned. Reported so a
    /// caller never claims a complete delete that did not happen.
    case projectionCleanupFailed(id: String, failures: [String])

    public var errorDescription: String? {
        switch self {
        case .threadDeleted: "That chat was deleted. Start a new chat to continue."
        case let .projectionCleanupFailed(_, failures):
            "The chat is gone, but its daily log entries could not be cleaned up: \(failures.joined(separator: "; "))"
        }
    }
}

/// RTI's durable chat store: the structured thread under the vault, the
/// submitted bytes under Application Support, and one commit path that writes
/// both or neither.
///
/// The roots are injected, so a test never touches the live store. The app uses
/// `applicationRoots()`.
///
/// One conversation is one record. A turn and the bytes it points at commit
/// together (`ChatCommitCoordinator`), so a crash cannot leave a turn pointing
/// at bytes nobody owns or bytes with no turn referring to them. Nothing here
/// evicts: deletion is explicit and reference-checked.
public actor ChatThreadStore {
    public struct Roots: Sendable {
        /// `~/Library/Application Support/RTI/chat-assets`.
        public let assets: URL
        /// `<vault>/databases/projects/personal/rti/chats/threads`.
        public let threads: URL
        /// Removes the compatibility projections this store wrote for one
        /// thread (its daily JSONL rows and Markdown blocks). Defaults to a
        /// NO-OP, so a temp store built directly never resolves the live vault
        /// config; `applicationRoots()` passes the vault turn log explicitly.
        public var removeProjections: @Sendable (String) -> VaultLogStore.ProjectionCleanup

        public init(
            assets: URL,
            threads: URL,
            removeProjections: @escaping @Sendable (String) -> VaultLogStore.ProjectionCleanup = { _ in
                VaultLogStore.ProjectionCleanup()
            }
        ) {
            self.assets = assets
            self.threads = threads
            self.removeProjections = removeProjections
        }
    }

    /// One thing the user submitted with a turn, as the commit needs it: the
    /// reference for the record, and the bytes the app actually has.
    public struct SubmittedAttachment: Sendable {
        public var kind: AttachmentKind
        public var name: String
        public var path: String?
        public var byteCount: Int?
        public var pageCount: Int?
        /// The user's original bytes, when the app has them. Never redacted.
        public var originalBytes: Data?
        public var originalExtension: String?
        /// The inference-normalized image, when the attachment is one.
        public var normalizedImage: Data?
        public var normalizedImageExtension: String?
        /// The text a model reads, when the app has it.
        public var extractedText: String?
        /// The extractor's record, when there is one. Stored as the
        /// `.extractedText` artifact so its sections — and therefore a
        /// follow-up's passage selection — survive a relaunch.
        public var extractedDocument: ExtractedDocument?
        /// True when the text was cut to fit a cap.
        public var wasCut: Bool = false

        public init(
            kind: AttachmentKind,
            name: String,
            path: String? = nil,
            byteCount: Int? = nil,
            pageCount: Int? = nil,
            originalBytes: Data? = nil,
            originalExtension: String? = nil,
            normalizedImage: Data? = nil,
            normalizedImageExtension: String? = nil,
            extractedText: String? = nil,
            extractedDocument: ExtractedDocument? = nil,
            wasCut: Bool = false
        ) {
            self.kind = kind
            self.name = name
            self.path = path
            self.byteCount = byteCount
            self.pageCount = pageCount
            self.originalBytes = originalBytes
            self.originalExtension = originalExtension
            self.normalizedImage = normalizedImage
            self.normalizedImageExtension = normalizedImageExtension
            self.extractedText = extractedText
            self.extractedDocument = extractedDocument
            self.wasCut = wasCut
        }
    }

    /// One attachment as it comes back out of the store, rehydrated for a
    /// follow-up turn.
    public struct RetainedAttachment: Sendable {
        public let name: String
        public let kind: AttachmentKind
        public let path: String?
        /// The extractor's record, decoded from the stored artifact.
        public let document: ExtractedDocument?
        /// The text a model may read, when the record has none.
        public let extractedText: String?
        /// The original bytes, when the store still has them.
        public let originalBytes: Data?
        /// The inference-normalized image, when the store still has it. This
        /// is what a follow-up sends to a vision model: the exact bytes that
        /// were committed, never a re-derivation.
        public let normalizedImage: Data?
        public let normalizedImageMimeType: String?
        /// True when the record points at bytes the store can no longer read.
        /// Never causes a refetch: the caller says so instead.
        public let isMissing: Bool

        public init(
            name: String,
            kind: AttachmentKind,
            path: String?,
            document: ExtractedDocument?,
            extractedText: String?,
            originalBytes: Data?,
            normalizedImage: Data?,
            normalizedImageMimeType: String?,
            isMissing: Bool
        ) {
            self.name = name
            self.kind = kind
            self.path = path
            self.document = document
            self.extractedText = extractedText
            self.originalBytes = originalBytes
            self.normalizedImage = normalizedImage
            self.normalizedImageMimeType = normalizedImageMimeType
            self.isMissing = isMissing
        }
    }

    public struct SubmittedTurn: Sendable {
        /// A stable turn id. When a turn with this id is already stored — a
        /// checkpoint written while the answer streamed — it is replaced
        /// instead of appended, so a turn is one row whatever happened.
        public var id: String? = nil
        public var text: String
        public var role: TurnRole = .user
        /// Chosen vs effective, in the shared schema's shape.
        public var model: ModelSelection?
        /// The full receipt: status, context decision, tool rounds, timings.
        public var request: RequestReceipt?
        public var toolRounds: [ToolRound] = []
        public var timings: TurnTimings = TurnTimings()
        /// Set on a failed turn; the answer that never arrived.
        public var error: String?
        /// The RTI session this turn belongs to, when one was recording. A
        /// thread created standalone and later continued in a recording keeps
        /// each turn's own link, so the recording's projection can name the
        /// turns it actually owns instead of guessing from the thread.
        public var sessionLinks: [SessionLink] = []
        public var attachments: [SubmittedAttachment] = []
        /// The credential-free request body, stored as a `.requestSnapshot`
        /// artifact and referenced from the receipt. Never contains a header or
        /// a key.
        public var requestSnapshot: Data? = nil
        public var requestSnapshotExtension: String = "json"

        public init(
            id: String? = nil,
            text: String,
            role: TurnRole = .user,
            model: ModelSelection? = nil,
            request: RequestReceipt? = nil,
            toolRounds: [ToolRound] = [],
            timings: TurnTimings = TurnTimings(),
            error: String? = nil,
            sessionLinks: [SessionLink] = [],
            attachments: [SubmittedAttachment] = [],
            requestSnapshot: Data? = nil,
            requestSnapshotExtension: String = "json"
        ) {
            self.id = id
            self.text = text
            self.role = role
            self.model = model
            self.request = request
            self.toolRounds = toolRounds
            self.timings = timings
            self.error = error
            self.sessionLinks = sessionLinks
            self.attachments = attachments
            self.requestSnapshot = requestSnapshot
            self.requestSnapshotExtension = requestSnapshotExtension
        }
    }

    private let attachments: AttachmentArchive
    private let conversations: ConversationArchive
    private let coordinator: ChatCommitCoordinator
    private let removeProjections: @Sendable (String) -> VaultLogStore.ProjectionCleanup
    /// Thread IDs deleted in this process. Appending to one is refused until a
    /// new chat is started on purpose, so an answer that was streaming when
    /// the chat was deleted cannot bring the deleted thread back.
    private var deletedThreadIDs: Set<String> = []
    /// One serial gate per thread.
    ///
    /// An actor alone does not stop two whole-record writes from interleaving:
    /// `conversations.load` and `conversations.save` are themselves awaits, so
    /// a rename can land between an append's re-read and its save, and the
    /// append's stale copy would win. Every mutation of one thread runs under
    /// that thread's gate, and different threads never block each other.
    private var gates: [String: ThreadGate] = [:]

    /// A serial gate. `enter()` suspends until the previous holder leaves.
    private actor ThreadGate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        public func enter() async {
            guard busy else {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        public func leave() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    /// Run `body` with this thread's gate held, so no other mutation of the
    /// same thread can interleave at an await.
    private func withThreadGate<T>(
        _ id: String,
        _ body: () async throws -> T
    ) async throws -> T {
        let gate = gates[id] ?? ThreadGate()
        gates[id] = gate
        await gate.enter()
        do {
            let value = try await body()
            await gate.leave()
            return value
        } catch {
            await gate.leave()
            throw error
        }
    }

    public init(roots: Roots) throws {
        let assets = try AttachmentArchive(root: roots.assets)
        let threads = try ConversationArchive(root: roots.threads)
        self.attachments = assets
        self.conversations = threads
        self.coordinator = ChatCommitCoordinator(attachments: assets, conversations: threads)
        self.removeProjections = roots.removeProjections
    }

    /// RTI's own roots, through the app's one resolver per location.
    public static func applicationRoots() -> Roots? {
        guard let rti = VaultPaths.rtiDirectory(),
              let support = AppSupportPaths.rtiDirectory(createIfNeeded: true)
        else { return nil }
        return Roots(
            assets: support.appendingPathComponent("chat-assets", isDirectory: true),
            threads: rti.appendingPathComponent("chats/threads", isDirectory: true),
            removeProjections: { VaultLogStore.removeOwnedProjections(threadID: $0) }
        )
    }

    /// The one store the app uses. The assistant and the chat library both go
    /// through this instance, so a rename or a pin that happens while an answer
    /// streams is written to the same serialized store instead of racing a
    /// second one.
    ///
    /// Throws when the roots exist but cannot be used. Nil when the app has no
    /// vault configured, which is the one case where chat runs without
    /// persisting.
    public static func shared() throws -> ChatThreadStore? {
        box.lock.lock()
        defer { box.lock.unlock() }
        if let resolved = box.resolved { return resolved }
        guard let roots = applicationRoots() else { return nil }
        let store = try ChatThreadStore(roots: roots)
        box.resolved = store
        return store
    }

    private static let box = SharedBox()

    /// Holds the one instance. `@unchecked Sendable` is guarded by `lock`, which
    /// also makes the lazy resolution single-flight.
    private final class SharedBox: @unchecked Sendable {
        public let lock = NSLock()
        public var resolved: ChatThreadStore?
    }

    /// The stored thread for `id`, or a fresh one.
    ///
    /// Loading first is what makes a resumed chat continue rather than replace
    /// what is already on disk. Only `.missing` starts a new thread: a damaged
    /// record, or one written by a newer schema, is thrown so the caller can
    /// refuse to write over history it could not read.
    public func thread(
        id: String,
        title: String?,
        surface: ChatSurface,
        session: SessionLink?,
        appVersion: String?
    ) async throws -> ConversationRecord {
        do {
            return try await conversations.load(id: id)
        } catch ConversationArchiveError.missing {
            // A deliberate new thread clears a deletion mark: this is the one
            // path that may create the id again.
            deletedThreadIDs.remove(id)
            let now = Date()
            return ConversationRecord(
                id: id,
                surface: surface,
                title: title,
                createdAt: now,
                updatedAt: now,
                sessionLinks: session.map { [$0] } ?? [],
                appVersion: appVersion
            )
        }
        // Every other failure (corrupt, unsupported schema, unreadable root,
        // unsafe root, bad id) propagates: never replace unreadable history.
    }

    /// Load a stored thread. Throws on anything but success, so a caller that
    /// wants to resume a chat can tell "absent" from "damaged".
    public func load(id: String) async throws -> ConversationRecord {
        try await conversations.load(id: id)
    }

    /// True when a thread with this id is already stored.
    public nonisolated func contains(id: String) -> Bool {
        conversations.contains(id)
    }

    /// Retitle a thread. `nil` clears the title.
    @discardableResult
    public func rename(id: String, title: String?) async throws -> ConversationRecord {
        try await mutate(id: id) { record in
            record.title = title
        }
    }

    /// Pin or unpin a thread. The schema has no pin field, so this is an
    /// app-namespaced field on the record, which is what `appPayload` is for.
    @discardableResult
    public func setPinned(id: String, _ pinned: Bool) async throws -> ConversationRecord {
        try await mutate(id: id) { record in
            var payload = record.appPayload ?? AppPayload(namespace: "rti")
            payload[Self.pinnedKey] = .bool(pinned)
            record.appPayload = payload
        }
    }

    public func isPinned(id: String) async throws -> Bool {
        let record = try await conversations.load(id: id)
        return record.appPayload?[Self.pinnedKey]?.boolValue ?? false
    }

    /// Load, change, save. One path, so a record is never written from a stale
    /// read.
    private func mutate(
        id: String,
        _ change: (inout ConversationRecord) -> Void
    ) async throws -> ConversationRecord {
        try await withThreadGate(id) { [self] in
            var record = try await conversations.load(id: id)
            change(&record)
            record.updatedAt = Date()
            _ = try await conversations.save(record)
            return record
        }
    }

    private static let pinnedKey = "pinned"

    /// Append one turn and commit its bytes. A throw means nothing was saved:
    /// the caller keeps the draft.
    ///
    /// The turn's own fields (role, text, model, receipt, tool rounds, timings,
    /// error) are stored as given, so a finished answer, a failed answer, and a
    /// cancelled answer all land in the same record with their own status.
    @discardableResult
    public func appendTurn(
        to conversation: ConversationRecord,
        turn: SubmittedTurn
    ) async throws -> TurnCommit {
        try await withThreadGate(conversation.id) { [self] in
            try await appendTurnLocked(to: conversation, turn: turn)
        }
    }

    private func appendTurnLocked(
        to conversation: ConversationRecord,
        turn: SubmittedTurn
    ) async throws -> TurnCommit {
        var record = conversation
        // A deleted thread is not silently recreated by an answer that was
        // already streaming when it went.
        guard !deletedThreadIDs.contains(conversation.id) else {
            throw ChatThreadStoreError.threadDeleted(id: conversation.id)
        }
        var attachmentRecords: [AttachmentRecord] = []
        var pending: [PendingArtifact] = []
        var request = turn.request

        for (index, item) in turn.attachments.enumerated() {
            let textCount = item.extractedText?.count
            let attachment = AttachmentRecord(
                id: UUID().uuidString,
                kind: item.kind,
                name: item.name,
                byteCount: item.byteCount,
                pageCount: item.pageCount,
                characterCount: textCount,
                truncation: item.wasCut ? TextTruncation(keptCharacters: textCount) : nil,
                contentHash: item.originalBytes.map(SHA256Digest.hex),
                path: item.path,
                addedAt: Date()
            )
            if let bytes = item.originalBytes {
                pending.append(PendingArtifact(
                    role: .original,
                    data: bytes,
                    fileExtension: item.originalExtension,
                    attachmentIndex: index
                ))
            }
            // The extractor's own record is what is stored: it carries the
            // text AND the sections, so a later follow-up can select passages
            // with their locations instead of starting from scratch.
            if let document = item.extractedDocument,
               let data = try? HouseChatCoding.makeEncoder().encode(document)
            {
                pending.append(PendingArtifact(
                    role: .extractedText,
                    data: data,
                    fileExtension: "json",
                    attachmentIndex: index
                ))
            } else if let text = item.extractedText, let data = text.data(using: .utf8) {
                pending.append(PendingArtifact(
                    role: .extractedText,
                    data: data,
                    fileExtension: "txt",
                    attachmentIndex: index
                ))
            }
            if let image = item.normalizedImage {
                pending.append(PendingArtifact(
                    role: .normalizedImage,
                    data: image,
                    fileExtension: item.normalizedImageExtension,
                    attachmentIndex: index
                ))
            }
            attachmentRecords.append(attachment)
        }

        // The credential-free request body is submitted to the SAME commit as
        // the conversation that references it, so it is written under one root
        // lock and can never be swept between the write and the reference. The
        // receipt is built from the bytes, so its hash and size match the
        // stored artifact by construction.
        if let snapshot = turn.requestSnapshot {
            pending.append(PendingArtifact(
                role: .requestSnapshot,
                data: snapshot,
                fileExtension: turn.requestSnapshotExtension,
                attachmentIndex: nil
            ))
            var receipt = request ?? RequestReceipt()
            receipt.attachmentRefs.append(AttachmentSnapshotRef(
                snapshotData: snapshot,
                kind: "request"
            ))
            request = receipt
        }

        // The record is re-read AFTER the artifact writes above, so a rename or
        // a pin that landed while this turn was being written is kept. The
        // reload and the save that follows have no await between them, so an
        // actor reentrancy point cannot open up inside that pair.
        do {
            record = try await conversations.load(id: conversation.id)
        } catch ConversationArchiveError.missing {
            // Not stored yet: the caller's fresh record is the base.
            record = conversation
        }
        guard !deletedThreadIDs.contains(record.id) else {
            throw ChatThreadStoreError.threadDeleted(id: record.id)
        }

        let stored = TurnRecord(
            id: turn.id ?? UUID().uuidString,
            role: turn.role,
            text: turn.text,
            createdAt: Date(),
            attachments: attachmentRecords,
            model: turn.model,
            request: request?.sanitizedForStorage(),
            toolRounds: turn.toolRounds,
            timings: turn.timings,
            sessionLinks: turn.sessionLinks,
            error: turn.error.map(SecretRedactor.redact)
        )
        // A replacement keeps the row count honest: a checkpointed answer and
        // its finished form are one turn, not two.
        let turnIndex: Int
        if let existing = record.turns.lastIndex(where: { $0.id == stored.id }) {
            record.turns[existing] = stored
            turnIndex = existing
        } else {
            record.turns.append(stored)
            turnIndex = record.turns.count - 1
        }
        record.updatedAt = Date()

        return try await coordinator.commit(
            conversation: record,
            turnIndex: turnIndex,
            artifacts: pending
        )
    }

    /// Total bytes this store owns, for the storage-usage line.
    public func storageUsage() async throws -> Int {
        let refs = try await attachments.list()
        return refs.reduce(0) { $0 + $1.byteCount }
    }

    /// Every byte the store holds, by kind, for a storage breakdown.
    public func artifacts(kind: ArtifactRef.Kind? = nil) async throws -> [ArtifactRef] {
        try await attachments.list(kind: kind)
    }

    /// The sources a thread was sent, read back from the store's own bytes.
    ///
    /// This is what makes a follow-up work after the original file moved or was
    /// deleted: the extracted record and the original bytes come from the
    /// archive, not from the path. A record whose bytes are gone is reported as
    /// missing and is never re-read from disk or refetched.
    public func retainedAttachments(id: String) async throws -> [RetainedAttachment] {
        let record = try await conversations.load(id: id)
        var retained: [RetainedAttachment] = []
        for attachment in record.attachments {
            var document: ExtractedDocument?
            var text: String?
            var missing = false

            if let ref = attachment.artifacts?.extractedText {
                do {
                    let data = try await attachments.read(ref)
                    if let decoded = try? HouseChatCoding.makeDecoder().decode(ExtractedDocument.self, from: data) {
                        document = decoded
                    } else {
                        text = String(data: data, encoding: .utf8)
                    }
                } catch {
                    missing = true
                }
            }

            var originalBytes: Data?
            if let ref = attachment.artifacts?.original {
                do {
                    originalBytes = try await attachments.read(ref)
                } catch {
                    missing = true
                }
            }

            var normalizedImage: Data?
            if let ref = attachment.artifacts?.normalizedImage {
                do {
                    normalizedImage = try await attachments.read(ref)
                } catch {
                    missing = true
                }
            }
            let normalizedImageMimeType = document?.normalizedImageMimeType
                ?? (attachment.kind == .screenshot ? "image/jpeg" : (normalizedImage == nil ? nil : "image/png"))

            retained.append(RetainedAttachment(
                name: attachment.name,
                kind: attachment.kind,
                path: attachment.path,
                document: document,
                extractedText: document?.text ?? text,
                originalBytes: originalBytes,
                normalizedImage: normalizedImage,
                normalizedImageMimeType: normalizedImageMimeType,
                isMissing: missing
            ))
        }
        return retained
    }

    /// Write the partial answer of a turn that is still streaming.
    ///
    /// Called periodically, so a process death leaves a recoverable record with
    /// the status the turn was actually in. The terminal write replaces it, and
    /// a terminal outcome is final: a checkpoint that was already inside this
    /// store when the terminal write landed is dropped rather than putting the
    /// turn back to `.streaming` and overwriting the answer the user saw.
    public func checkpoint(
        conversationID: String,
        turnID: String,
        text: String,
        startedAt: Date,
        model: ModelSelection?,
        toolRounds: [ToolRound] = []
    ) async throws {
        try await withThreadGate(conversationID) { [self] in
            var record = try await conversations.load(id: conversationID)
            guard !deletedThreadIDs.contains(conversationID) else {
                throw ChatThreadStoreError.threadDeleted(id: conversationID)
            }
            if let index = record.turns.lastIndex(where: { $0.id == turnID }) {
                guard !Self.isTerminal(record.turns[index].request?.status) else { return }
                record.turns[index].text = text
                record.turns[index].request?.status = .streaming
                if !toolRounds.isEmpty { record.turns[index].toolRounds = toolRounds }
            } else {
                let receipt = RequestReceipt(
                    selection: model,
                    status: .streaming,
                    toolRounds: toolRounds,
                    startedAt: startedAt
                )
                record.turns.append(TurnRecord(
                    id: turnID,
                    role: .assistant,
                    text: text,
                    createdAt: startedAt,
                    model: model,
                    request: receipt,
                    toolRounds: toolRounds
                ))
            }
            record.updatedAt = Date()
            _ = try await conversations.save(record)
        }
    }

    /// The chats a recording owns, exactly: a thread belongs to a session only
    /// when its own link names that session id. Nothing is inferred from dates
    /// or from what happened to be on screen at the time.
    ///
    /// A sibling that cannot be read is counted, not thrown and not hidden, so
    /// the projection can say that a stored chat is missing from it. Only the
    /// two "this file is not usable" errors are tolerated; anything else
    /// propagates, because an unreadable root is a different problem from one
    /// damaged file.
    public func sessionChatProjection(
        linkedToSession sessionID: String
    ) async -> (threads: [ChatProjectionMarkdown.Thread], unreadable: Int) {
        var threads: [ChatProjectionMarkdown.Thread] = []
        var unreadable = 0
        let summaries: [ConversationSummary]
        do {
            summaries = try await conversations.list()
        } catch {
            RTILog.log("could not list stored chats: \(error)", category: .llm)
            return ([], 0)
        }
        for summary in summaries {
            let record: ConversationRecord
            do {
                record = try await conversations.load(id: summary.id)
            } catch ConversationArchiveError.corrupt, ConversationArchiveError.unsupportedSchema {
                unreadable += 1
                continue
            } catch {
                RTILog.log("could not read chat \(summary.id): \(error)", category: .llm)
                unreadable += 1
                continue
            }
            guard record.sessionLinks.contains(where: { $0.id == sessionID })
                || record.turns.contains(where: { turn in
                    turn.sessionLinks.contains(where: { $0.id == sessionID })
                })
            else { continue }
            // Which turns the recording actually owns. A turn with its own
            // session link matches exactly. A turn carrying no link is
            // included only when the thread itself was created inside this
            // recording: that is the legacy shape, and it is not a guess
            // about a date.
            let threadMatches = record.sessionLinks.contains(where: { $0.id == sessionID })
            let matchingTurns = record.turns.filter { turn in
                if turn.sessionLinks.contains(where: { $0.id == sessionID }) { return true }
                return turn.sessionLinks.isEmpty && threadMatches
            }
            guard !matchingTurns.isEmpty else { continue }
            threads.append(ChatProjectionMarkdown.Thread(
                id: record.id,
                title: record.title,
                createdAt: record.createdAt,
                turns: matchingTurns.map { turn in
                    ChatProjectionMarkdown.Turn(
                        id: turn.id,
                        role: turn.role == .assistant ? "assistant" : "user",
                        text: turn.text,
                        createdAt: turn.createdAt,
                        status: turn.request?.status.rawValue
                    )
                }
            ))
        }
        threads.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return (threads, unreadable)
    }

    /// Any turn a process death left mid-answer becomes a cancelled turn with
    /// its reason, so a resumed chat shows what happened instead of a promise.
    /// Returns how many turns were marked.
    @discardableResult
    public func markInterrupted(id: String) async throws -> Int {
        try await withThreadGate(id) { [self] in
            var record = try await conversations.load(id: id)
            var marked = 0
            for index in record.turns.indices where record.turns[index].request?.status == .streaming {
                record.turns[index].request?.status = .cancelled
                record.turns[index].error = "Interrupted: RTI stopped before this answer finished."
                marked += 1
            }
            guard marked > 0 else { return 0 }
            record.updatedAt = Date()
            _ = try await conversations.save(record)
            return marked
        }
    }

    // MARK: Reading and housekeeping

    /// A status a turn never leaves. A checkpoint that lands after one of these
    /// is stale by definition.
    private static func isTerminal(_ status: RequestStatus?) -> Bool {
        switch status {
        case .completed, .cancelled, .failed, .refused: true
        case .pending, .streaming, .unknown, .none: false
        }
    }

    public func summaries() async throws -> [ConversationSummary] {
        try await conversations.list()
    }

    public func export(id: String) async throws -> Data {
        try await conversations.export(id: id)
    }

    /// Every byte this thread points at: attachment originals, normalized
    /// images, extracted text, and request snapshots.
    public func ownedArtifactRefs(id: String) async throws -> [ArtifactRef] {
        var refs: [ArtifactRef] = []
        let record = try await conversations.load(id: id)
        for attachment in record.attachments {
            for ref in [
                attachment.artifacts?.original,
                attachment.artifacts?.normalizedImage,
                attachment.artifacts?.extractedText,
            ] {
                if let ref { refs.append(ref) }
            }
        }
        for snapshot in record.turns.flatMap({ $0.request?.attachmentRefs ?? [] }) {
            guard let hash = snapshot.snapshotHash else { continue }
            refs.append(ArtifactRef(
                kind: .requestSnapshot,
                sha256: hash,
                byteCount: snapshot.byteCount ?? 0
            ))
        }
        // A ref with a zero byte count cannot be used to delete anything: the
        // store verifies size on read, so a guessed one would be refused. Drop
        // the ones we could not describe.
        return refs.filter { !$0.sha256.isEmpty && SHA256Digest.isValid($0.sha256) }
    }

    /// Delete one thread: the record, then the bytes only it still owned.
    ///
    /// The order matters. The record's refs are collected first, the record is
    /// deleted, and only then is the unreferenced sweep attempted. That sweep
    /// fails closed: if any other stored conversation cannot be read, it throws
    /// and nothing is removed, so a damaged sibling can never cause another
    /// chat's bytes to be deleted. A throw after the record is gone leaves
    /// orphaned bytes, which is safe (nothing evicts) and retryable.
    ///
    /// Projections (the daily turn log's JSONL rows, its Markdown chat blocks)
    /// ARE cleaned here, by exact thread id, through the injected remover: an
    /// unlinked legacy row is never assumed to belong to this thread, and no
    /// source, meeting, or recording is touched. A projection that cannot be
    /// cleaned throws after the record is gone, so a caller never reports a
    /// complete delete that did not happen.
    @discardableResult
    public func delete(id: String) async throws -> [ArtifactRef] {
        let owned = try await withThreadGate(id) { [self] in
            let refs = try await ownedArtifactRefs(id: id)
            try await conversations.delete(id: id)
            // Remembered, so an in-flight answer cannot append the thread back.
            deletedThreadIDs.insert(id)
            return refs
        }
        var swept: [ArtifactRef] = []
        if !owned.isEmpty {
            swept = try await removeArtifactsIfUnreferenced(owned)
        }
        // The daily JSONL rows and Markdown chat blocks this thread wrote are
        // compatibility projections that carry this exact thread id. They are
        // removed by id only: an unlinked legacy row is not this thread's and
        // is never touched, and nothing here removes a source, a meeting, or
        // a recording. A projection that cannot be cleaned is reported, not
        // silently left behind.
        let cleanup = removeProjections(id)
        if !cleanup.isClean {
            throw ChatThreadStoreError.projectionCleanupFailed(id: id, failures: cleanup.failures)
        }
        return swept
    }

    /// Verifies the bytes and the size before returning them.
    public func read(_ ref: ArtifactRef) async throws -> Data {
        try await attachments.read(ref)
    }

    public func verify(_ ref: ArtifactRef) async throws -> ArtifactVerification {
        try await attachments.verify(ref)
    }

    /// Deletes bytes only when no stored chat still refers to them, so the
    /// user's originals are never removed while a thread points at them.
    ///
    /// Deleting bytes is the coordinator's job: it holds the root lock and
    /// reads every readable conversation, so a blob still named by a receipt
    /// is never removed. Nothing here has to guess.
    public func removeArtifactsIfUnreferenced(_ refs: [ArtifactRef]) async throws -> [ArtifactRef] {
        try await coordinator.removeArtifactsIfUnreferenced(refs)
    }

    /// Storage usage per artifact kind, for the storage line.
    public func storageUsageByKind() async throws -> [ArtifactRef.Kind: Int] {
        var usage: [ArtifactRef.Kind: Int] = [:]
        for ref in try await attachments.list() {
            usage[ref.kind, default: 0] += ref.byteCount
        }
        return usage
    }
}

public extension ChatThreadStore {
    /// The documented pin key.
    ///
    /// A pin is app state the shared schema does not model, so it lives where
    /// the package says app-only fields go: `ConversationRecord.appPayload`,
    /// namespace `"rti"`, key `"pinned"`, value a JSON bool. It survives a
    /// round trip through either app and never becomes a shared field.
    static var pinnedPayloadKey: String { "pinned" }
    static var payloadNamespace: String { "rti" }
}
