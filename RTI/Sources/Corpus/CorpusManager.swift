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
    nonisolated static let shared = CorpusManager()

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

    nonisolated static let corpusPathKey = "rti.corpus.path"

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
        let speakerKeys = Set(turns.map(\.speakerId)).filter { $0 != "note" }
        let overlays: [String: SpeakerOverlay]
        do {
            overlays = try await RTIDatabase.shared.pool.read { db in
                var found: [String: SpeakerOverlay] = [:]
                for key in speakerKeys {
                    if let overlay = try SpeakerOverlay.resolve(speakerKey: key, sessionId: sessionId, in: db) {
                        found[key] = overlay
                    }
                }
                return found
            }
        } catch {
            // Non-critical; continue without speaker info.
            overlays = [:]
        }
        let speakerMap: [String: CorpusEntry.SpeakerMapEntry] = overlays.mapValues { overlay in
            .init(name: overlay.displayName, source: overlay.source)
        }
        let attendees = speakerMap.values.map(\.name).sorted()

        // Pull persisted notes + dossiers (v12 tables) so they land in the
        // canonical markdown alongside the transcript and summary. Until
        // this they only existed in the live panels and the per-session
        // detail view.
        let notesMarkdown = Self.notesMarkdown(forSessionId: sessionId)
        let entitiesMarkdown = Self.entitiesMarkdown(forSessionId: sessionId)

        // Snapshot project membership at render time. The `project_sessions`
        // table is the canonical record; the markdown frontmatter stores
        // both id (durable) and name (human-readable for `cat foo.md`).
        let projectId = await MainActor.run { () -> String? in
            ProjectStore.shared.projects.first(where: {
                ProjectStore.shared.sessionIds(forProject: $0.id).contains(sessionId)
            })?.id
        }
        let projectName = await MainActor.run { () -> String? in
            guard let projectId else { return nil }
            return ProjectStore.shared.projects.first { $0.id == projectId }?.name
        }

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
            notesMarkdown: notesMarkdown,
            entitiesMarkdown: entitiesMarkdown,
            turns: turns,
            projectId: projectId,
            projectName: projectName
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
        // Orphans are recovered as part of the next session-end render via
        // CorpusFTSReindexer + recovery handling elsewhere. No UI surface
        // wires `.rtiOrphansDetected` today, so we don't post it — a future
        // banner can subscribe and we'll re-introduce the post then.
    }

    // MARK: - Analysis sections

    /// Build the `## Notes` body from persisted GeneratedNote rows for
    /// `sessionId`. Returns nil when there are none, so the renderer can
    /// skip the section header entirely.
    private static func notesMarkdown(forSessionId sessionId: String) -> String? {
        let notes = NotesGenerationController.loadNotes(forSessionId: sessionId)
        guard !notes.isEmpty else { return nil }
        let parts: [String] = notes.map { n in
            let when = n.timestamp.formatted(date: .omitted, time: .shortened)
            return "### \(when)\n\n\(n.content)"
        }
        return parts.joined(separator: "\n\n")
    }

    /// Build the `## Entities` body from persisted EntityDossier rows for
    /// `sessionId`, grouped by entity type. Returns nil when empty.
    private static func entitiesMarkdown(forSessionId sessionId: String) -> String? {
        let dossiers = DossierController.loadDossiers(forSessionId: sessionId)
        guard !dossiers.isEmpty else { return nil }
        let grouped = Dictionary(grouping: dossiers) { $0.type }
            .sorted { $0.key.displayName < $1.key.displayName }
        let sections: [String] = grouped.map { (type, items) in
            let body: [String] = items.map { "- **\($0.name)** — \($0.description)" }
            return "### \(type.displayName)\n\n\(body.joined(separator: "\n"))"
        }
        return sections.joined(separator: "\n\n")
    }
}
