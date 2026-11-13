import Foundation
import RTICore

extension Notification.Name {
    /// A chat turn's final answer (completed, failed or stopped) was filed in
    /// the thread store. `userInfo["sessionIDs"]` holds the recordings the
    /// turn is linked to.
    static let rtiChatTurnFiled = Notification.Name("rtiChatTurnFiled")
}

/// NET-7: Stop does not wait for an answer still streaming. The archive's
/// `chat.md` and the `-rti.md` sidecar for `/meeting` are written from the
/// thread store as it was at Stop, so they held a cut or empty answer for
/// good. This keeps the stopped recording's snapshot until the next one
/// starts, and when a turn linked to it is filed later, it reads the
/// recording's chats again and rewrites only `chat.md` and the sidecar.
///
/// F2 (batch 6): the same holds for a notes block that lands after the
/// archive ("Write notes now" after Stop, or a manual pass Stop did not wait
/// for). It rewrites only `notes.md` and the sidecar, so the block on screen
/// is the block on disk before the next Record clears the Notes tab.
@MainActor
final class LateChatArchiveRefresher {
    struct Target {
        let sessionID: String
        var snapshot: SessionFinalizer.Snapshot?
        var archiveDir: URL?
        var callType: CallType = .client
        /// A turn was filed after Stop but before the archive was written.
        var filedBeforeArchive = false
    }

    private(set) var target: Target?
    private let store: () throws -> ChatThreadStore?
    /// Set once in init, read only in deinit.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private nonisolated(unsafe) var notesObserver: NSObjectProtocol?
    /// Rewrites run one at a time, in filing order.
    private var refreshTask: Task<Void, Never>?

    /// Shows a late write that failed; the block is still only on screen.
    private let reportFailure: (String) -> Void

    init(store: @escaping () throws -> ChatThreadStore? = { try ChatThreadStore.shared() },
         reportFailure: @escaping (String) -> Void = { SessionCoordinator.shared.lastError = $0 })
    {
        self.store = store
        self.reportFailure = reportFailure
        observer = NotificationCenter.default.addObserver(forName: .rtiChatTurnFiled, object: nil, queue: .main) { [weak self] note in
            let ids = note.userInfo?["sessionIDs"] as? [String] ?? []
            MainActor.assumeIsolated { self?.turnFiled(sessionIDs: ids) }
        }
        notesObserver = NotificationCenter.default.addObserver(forName: .rtiNotesBlockAdded, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? String,
                  let notes = note.userInfo?["notes"] as? [GeneratedNote] else { return }
            MainActor.assumeIsolated { self?.notesAdded(sessionID: id, notes: notes) }
        }
    }

    deinit {
        for observer in [observer, notesObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Stop was pressed: from now on a filed turn of this recording counts.
    /// Forgets the previous recording. Kept through the next call on purpose:
    /// starting it cancels a stream still running, and that cut answer is
    /// filed (with its stopped status) after the start.
    func begin(sessionID: String) {
        target = Target(sessionID: sessionID)
    }

    /// The archive and the sidecar were written from `snapshot`.
    func archived(sessionID: String, snapshot: SessionFinalizer.Snapshot, archiveDir: URL?, callType: CallType) {
        guard target?.sessionID == sessionID, let archiveDir else { return }
        target?.snapshot = snapshot
        target?.archiveDir = archiveDir
        target?.callType = callType
        if target?.filedBeforeArchive == true {
            target?.filedBeforeArchive = false
            scheduleRefresh()
        }
    }

    func turnFiled(sessionIDs: [String]) {
        guard let target, sessionIDs.contains(target.sessionID) else { return }
        guard target.snapshot != nil else {
            self.target?.filedBeforeArchive = true
            return
        }
        scheduleRefresh()
    }

    /// A notes block landed. Before the archive the Stop snapshot reads the
    /// controller's list itself, so only a block after it needs a rewrite.
    func notesAdded(sessionID: String, notes: [GeneratedNote]) {
        guard target?.sessionID == sessionID, let snapshot = target?.snapshot, snapshot.notes != notes else { return }
        target?.snapshot?.notes = notes
        let previous = refreshTask
        refreshTask = Task { @MainActor [weak self] in
            await previous?.value
            self?.rewriteNotes()
        }
    }

    /// The pending rewrite, for tests.
    func settled() async {
        await refreshTask?.value
    }

    private func scheduleRefresh() {
        let previous = refreshTask
        refreshTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.refresh()
        }
    }

    private func rewriteNotes() {
        guard let target, let snapshot = target.snapshot, let archiveDir = target.archiveDir else { return }
        let wroteNotes = SessionArchive.writeNotes(
            in: archiveDir, startedAt: snapshot.startedAt, endedAt: snapshot.endedAt, notes: snapshot.notes,
            workstreamSlug: SessionFinalizer.workstreamSlug(for: snapshot.workstreamItem)
        )
        let sidecar = SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: archiveDir, callType: target.callType)
        if wroteNotes, sidecar != nil {
            RTILog.log("late notes block added to \(archiveDir.lastPathComponent)/notes.md and the -rti.md sidecar", category: .archive)
        } else {
            RTILog.log("late notes block could not be added to \(archiveDir.lastPathComponent)", level: .error, category: .archive)
            reportFailure("The newest notes block could not be saved to the session folder. "
                + "Copy it from the Notes tab before you start the next recording, which clears the tab.")
        }
    }

    private func refresh() async {
        guard let target, var snapshot = target.snapshot, let archiveDir = target.archiveDir else { return }
        let projection: (threads: [ChatProjectionMarkdown.Thread], unreadable: Int)
        do {
            guard let store = try store() else { return }
            projection = await store.sessionChatProjection(linkedToSession: target.sessionID)
        } catch {
            RTILog.log("late chat answer not added to the archive: the chat store could not be opened: \(error)", level: .error, category: .archive)
            return
        }
        // The next recording may have started while the store was read.
        guard self.target?.sessionID == target.sessionID, !projection.threads.isEmpty else { return }
        snapshot.chatThreads = projection.threads
        snapshot.unreadableChatCount = projection.unreadable
        self.target?.snapshot = snapshot
        let wroteChat = SessionArchive.writeChat(
            in: archiveDir, startedAt: snapshot.startedAt, endedAt: snapshot.endedAt, chat: snapshot.chat,
            chatThreads: snapshot.chatThreads, unreadableChatCount: snapshot.unreadableChatCount,
            workstreamSlug: SessionFinalizer.workstreamSlug(for: snapshot.workstreamItem)
        )
        let sidecar = SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: archiveDir, callType: target.callType)
        if wroteChat, sidecar != nil {
            RTILog.log("late chat answer added to \(archiveDir.lastPathComponent)/chat.md and the -rti.md sidecar", category: .archive)
        } else {
            RTILog.log("late chat answer could not be added to \(archiveDir.lastPathComponent); the full answer stays in the chat thread", level: .error, category: .archive)
        }
    }
}
