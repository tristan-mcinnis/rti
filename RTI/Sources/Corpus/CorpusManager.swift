import AppKit
import Foundation
import GRDB

/// Top-level coordinator for the markdown Corpus. Owns:
///   - the corpus directory location (`~/meetings/` by default)
///   - the session-end render flow (JSONL + caches → markdown)
///   - crash-recovery scan on launch
///
/// Runtime JSONL writing during live sessions lives in `LiveSessionStore`
/// so the recording path and the render path are separate modules.
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

    nonisolated static let corpusPathKey = "rti.corpus.path"

    nonisolated private init() {}

    // MARK: - Session-end render

    /// Build a markdown file from the session's live JSONL stream + the
    /// in-memory title/summary caches. Returns the file URL on success,
    /// nil on no-op.
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
        LiveSessionStore.shared.closeLive(sessionId: sessionId)
        let liveURL = LiveSessionStore.shared.liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let events = (try? LiveJSONLReader.readAll(liveURL)) ?? []
        let turns = MarkdownRenderer.turns(from: events)
        let title = SessionTitleController.shared.cachedTitle(forSessionId: sessionId)
        let summaryText = SummaryController.shared.cachedSummary(forSessionId: sessionId)?.summaryText

        // Skip if there's nothing to write.
        guard !turns.isEmpty || (summaryText?.isEmpty == false) else {
            // Still drop the JSONL — empty session, no value in keeping it.
            LiveSessionStore.shared.deleteLive(sessionId: sessionId)
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

        // Pull persisted notes + dossiers so they land in the canonical
        // markdown alongside the transcript and summary.
        let notesMarkdown = Self.notesMarkdown(forSessionId: sessionId)
        let entitiesMarkdown = Self.entitiesMarkdown(forSessionId: sessionId)

        // Snapshot project membership at render time.
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
                try CorpusIndexer.reindex(from: corpusDirectory, in: RTIDatabase.shared.pool)
            } catch {
                NSLog("[RTI] CorpusManager FTS reindex failed: \(error)")
            }
            // JSONL no longer needed; markdown is canonical.
            LiveSessionStore.shared.deleteLive(sessionId: sessionId)
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
        let liveDir = LiveSessionStore.shared.liveDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: liveDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let orphans = urls.filter { $0.pathExtension == "jsonl" }
        for url in orphans {
            NSLog("[RTI] CorpusManager: orphaned live JSONL at \(url.path)")
        }
    }

    // MARK: - Analysis sections

    /// Build the `## Notes` body from persisted GeneratedNote rows for
    /// `sessionId`. Returns nil when there are none.
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
