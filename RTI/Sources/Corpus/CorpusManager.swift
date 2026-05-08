import AppKit
import Foundation
import GRDB

/// Top-level coordinator for the markdown Corpus. Owns:
///   - the corpus directory location (`~/meetings/` by default)
///   - per-session `LiveJSONLWriter`s during active sessions
///   - the session-end render flow (JSONL + caches → markdown)
///   - crash-recovery scan on launch
@MainActor
final class CorpusManager {
    static let shared = CorpusManager()

    nonisolated var corpusDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: Self.corpusPathKey),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("meetings", isDirectory: true)
    }

    nonisolated var liveDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RTI/live", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let corpusPathKey = "rti.corpus.path"

    private var writers: [String: LiveJSONLWriter] = [:]

    private init() {}

    // MARK: - Live JSONL

    @discardableResult
    func openLive(sessionId: String) -> LiveJSONLWriter {
        if let existing = writers[sessionId] { return existing }
        let url = liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let writer = LiveJSONLWriter(url: url)
        do {
            try writer.open()
        } catch {
            NSLog("[RTI] CorpusManager: live open failed: \(error)")
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

    // MARK: - Session-end render

    /// Build a markdown file from the session's live JSONL stream + the
    /// in-memory title/summary caches. Phase 4 final shape: no SQLite
    /// reads. Returns the file URL on success, nil on no-op.
    @discardableResult
    func renderSession(
        sessionId: String,
        startedAt: Date,
        endedAt: Date?,
        wavPath: String?,
        modeId: String?
    ) async -> URL? {
        // Close + flush JSONL so any pending writes are on disk before we
        // read it.
        writers[sessionId]?.close()
        let liveURL = liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let events = (try? LiveJSONLReader.readAll(liveURL)) ?? []
        let turns = MarkdownRenderer.turns(from: events)
        let title = SessionTitleController.shared.cachedTitle(forSessionId: sessionId)
        let summaryText = SummaryController.shared.cachedSummary(forSessionId: sessionId)?.summaryText

        // Skip if there's nothing to write.
        guard !turns.isEmpty || (summaryText?.isEmpty == false) else {
            // Still drop the JSONL — empty session, no value in keeping it.
            deleteLive(sessionId: sessionId)
            return nil
        }

        // Speaker map snapshot from overlays.
        var speakerMap: [String: CorpusEntry.SpeakerMapEntry] = [:]
        let speakerKeys = Set(turns.map(\.speakerId)).filter { $0 != "note" }
        do {
            try await RTIDatabase.shared.pool.read { db in
                for key in speakerKeys {
                    if let overlay = try SpeakerOverlay.resolve(speakerKey: key, sessionId: sessionId, in: db) {
                        speakerMap[key] = .init(name: overlay.displayName, source: overlay.source)
                    }
                }
            }
        } catch {
            NSLog("[RTI] CorpusManager overlay lookup failed: \(error)")
        }
        let attendees = speakerMap.values.map(\.name).sorted()

        let inputs = MarkdownRenderer.Inputs(
            id: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            modeId: modeId,
            transcriptQuality: nil,
            wavPath: wavPath,
            attendees: attendees.isEmpty ? nil : attendees,
            speakerMap: speakerMap.isEmpty ? nil : speakerMap,
            keyTopics: nil,
            summaryMarkdown: summaryText,
            turns: turns
        )
        let entry = MarkdownRenderer.make(inputs)
        let slug = CorpusWriter.slug(forTitle: title, date: startedAt)
        do {
            let url = try CorpusWriter.write(entry, to: corpusDirectory, slug: slug)
            do {
                try CorpusFTSReindexer.reindex(from: corpusDirectory, in: RTIDatabase.shared.pool)
            } catch {
                NSLog("[RTI] CorpusManager FTS reindex failed: \(error)")
            }
            // JSONL no longer needed; markdown is canonical.
            deleteLive(sessionId: sessionId)
            // Drop in-memory caches now that markdown is the durable record.
            SessionTitleController.shared.purgeCache(forSessionId: sessionId)
            SummaryController.shared.purgeCache(forSessionId: sessionId)
            return url
        } catch {
            NSLog("[RTI] CorpusManager renderSession failed: \(error)")
            return nil
        }
    }

    // MARK: - Recovery

    /// Scan `liveDirectory` for orphaned JSONL files (sessions that didn't
    /// reach a clean session-end render) and surface them.
    func recoverOrphans() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: liveDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let orphans = urls.filter { $0.pathExtension == "jsonl" }
        for url in orphans {
            NSLog("[RTI] CorpusManager: orphaned live JSONL at \(url.path)")
        }
        if !orphans.isEmpty {
            NotificationCenter.default.post(name: .rtiOrphansDetected, object: orphans)
        }
    }


}
