import Foundation

/// Per-session live JSONL writer management. Owns the `liveDirectory` and
/// the dictionary of open writers. Extracted from `CorpusManager` so the
/// runtime recording path and the session-end render path are separate
/// modules.
///
/// During a live session, `TranscriptPipeline` and `SessionCoordinator`
/// write events here. At session end, `CorpusManager.renderSession` reads
/// the accumulated JSONL to produce canonical markdown.
@MainActor
final class LiveSessionStore {
    nonisolated static let shared = LiveSessionStore()

    nonisolated var liveDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RTI/live", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var writers: [String: LiveJSONLWriter] = [:]

    nonisolated private init() {}

    // MARK: - Live JSONL

    @discardableResult
    func openLive(sessionId: String) -> LiveJSONLWriter {
        if let existing = writers[sessionId] { return existing }
        let url = liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let writer = LiveJSONLWriter(url: url)
        do {
            try writer.open()
        } catch {
            NSLog("[RTI] LiveSessionStore: live open failed: \(error)")
        }
        writers[sessionId] = writer
        return writer
    }

    func liveWriter(sessionId: String) -> LiveJSONLWriter? {
        writers[sessionId]
    }

    func closeLive(sessionId: String) {
        writers[sessionId]?.close()
    }

    func deleteLive(sessionId: String) {
        if let w = writers[sessionId] {
            w.deleteFile()
            writers.removeValue(forKey: sessionId)
        } else {
            let url = liveDirectory.appendingPathComponent("\(sessionId).jsonl")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
