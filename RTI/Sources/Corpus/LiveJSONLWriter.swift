import Foundation

/// Append-only JSONL writer for an in-flight session. One file per session
/// at `~/Library/Application Support/RTI/live/<session-id>.jsonl`. Survives
/// crashes; the `CorpusFTSReindexer` and the MCP server both can tail this
/// file while a session is active.
///
/// Thread-safe: callers may invoke `append` from any thread; writes are
/// serialised through a private queue, and the file handle is `fsync`ed
/// at most once per ~250ms via debounced flush.
final class LiveJSONLWriter: @unchecked Sendable {
    enum Event: Codable {
        case word(ts: Int, speaker: Int, text: String, isFinal: Bool, confidence: Double, channel: String)
        case note(ts: Int, text: String)
        case chat(ts: Int, role: String, content: String)
    }

    private let url: URL
    private let queue = DispatchQueue(label: "rti.live.jsonl", qos: .utility)
    private var handle: FileHandle?
    /// Once `close()` runs, late-arriving `append()` calls (queued before
    /// shutdown but executed after) must not silently reopen the file —
    /// otherwise events written past the point the renderer already read
    /// vanish from the markdown corpus.
    private var closed: Bool = false
    private var pendingFlush: DispatchWorkItem?
    private let flushInterval: TimeInterval = 0.25
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(url: URL) {
        self.url = url
    }

    /// Open or create the file. Idempotent — safe to call multiple times.
    func open() throws {
        try queue.sync {
            try _open()
        }
    }

    private func _open() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if handle == nil {
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
        }
    }

    func append(_ event: Event) {
        queue.async { [weak self] in
            guard let self else { return }
            // Drop late events that race past close(): silently re-opening
            // the file would write past the cursor the corpus renderer
            // already read, losing those events from the markdown.
            if self.closed {
                // NSLog (not RTILog) — this file is shared with the rti-mcp
                // standalone CLI target, which doesn't link AppLog.
                NSLog("[RTI] LiveJSONLWriter append after close — dropping event")
                return
            }
            do {
                if self.handle == nil {
                    try self._open()
                }
                guard let h = self.handle else { return }
                var data = try self.encoder.encode(event)
                data.append(0x0A) // newline
                try h.write(contentsOf: data)
                self.scheduleFlushLocked()
            } catch {
                NSLog("[RTI] LiveJSONLWriter append failed: \(error)")
            }
        }
    }

    /// Force a flush + close. Called on session-end after rendering markdown.
    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            pendingFlush?.cancel()
            pendingFlush = nil
            closed = true
        }
    }

    /// Delete the JSONL file. Called after a successful markdown render so
    /// orphan-recovery doesn't process it again on next launch.
    func deleteFile() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    private func scheduleFlushLocked() {
        // Already running on `queue` — no need for additional sync. Debounce
        // fsyncs so we don't pay the syscall on every word.
        pendingFlush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.handle?.synchronize()
        }
        pendingFlush = item
        queue.asyncAfter(deadline: .now() + flushInterval, execute: item)
    }
}

/// Read-side helper. Used by recovery + the MCP `read_live_transcript`
/// tool. Stateless; reopens the file on each call.
enum LiveJSONLReader {
    static func readAll(_ url: URL) throws -> [LiveJSONLWriter.Event] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var out: [LiveJSONLWriter.Event] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8) else {
                throw CorpusError.malformedJSONLLine(line.prefix(100).description)
            }
            // Tolerate a partial last line — readers may catch the file
            // mid-write. Skip events we can't decode rather than throwing.
            if let event = try? decoder.decode(LiveJSONLWriter.Event.self, from: data) {
                out.append(event)
            }
        }
        return out
    }

    /// Returns just the events past `sinceLine` (zero-indexed line cursor).
    /// MCP `read_live_transcript` uses this to deliver deltas to polling
    /// agents without re-sending the full transcript.
    static func readSince(_ url: URL, sinceLine: Int) throws -> (events: [LiveJSONLWriter.Event], nextLine: Int) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard sinceLine < lines.count else {
            return ([], lines.count)
        }
        let decoder = JSONDecoder()
        var out: [LiveJSONLWriter.Event] = []
        for line in lines[sinceLine...] {
            if let data = line.data(using: .utf8),
               let event = try? decoder.decode(LiveJSONLWriter.Event.self, from: data) {
                out.append(event)
            }
        }
        return (out, lines.count)
    }
}
