import Foundation
import GRDB

/// Watches the corpus directory for file changes (atomic writes from the
/// host, atomic writes from `rti-mcp append_to_session`, manual edits to
/// markdown files) and triggers an FTS + dense reindex.
///
/// The reindex pair is the same one `CorpusManager` runs after a session
/// finalises — keeping the index fresh against the on-disk markdown is the
/// only contract. Debounced so a burst of writes (e.g. agent appending
/// several action items) collapses into one reindex.
@MainActor
final class CorpusWatcher {
    private let directory: URL
    private let dbPool: DatabaseWriter
    private let debounce: TimeInterval

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pendingItem: DispatchWorkItem?
    private let workQueue = DispatchQueue(label: "rti.corpus-watcher", qos: .utility)

    init(directory: URL, dbPool: DatabaseWriter, debounce: TimeInterval = 0.75) {
        self.directory = directory
        self.dbPool = dbPool
        self.debounce = debounce
    }

    /// Begin watching. Safe to call multiple times — re-arms the source.
    func start() {
        stop()
        // `O_EVTONLY` opens the directory just for fsevents — no read/write
        // perms required, no FD leak on the actual data.
        let path = directory.path
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            RTILog.log("CorpusWatcher: failed to open \(path) (errno=\(errno))", category: "corpus-watcher")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: workQueue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleReindex()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        src.resume()
        source = src
    }

    func stop() {
        pendingItem?.cancel()
        pendingItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        // `deinit` can't touch `@MainActor`-isolated properties, but the
        // dispatch source's cancel handler closes the fd on its own queue.
        source?.cancel()
    }

    private func scheduleReindex() {
        // Coalesce bursts: each event cancels the previous pending reindex
        // and schedules a fresh one `debounce` seconds out.
        pendingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.runReindex()
        }
        pendingItem = item
        workQueue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func runReindex() {
        do {
            try CorpusFTSReindexer.reindex(from: directory, in: dbPool)
            try CorpusIndexer.reindex(from: directory, in: dbPool)
        } catch {
            RTILog.log("CorpusWatcher reindex failed: \(error)", category: "corpus-watcher")
        }
    }
}
