import Foundation
import os
import RTICore

/// Writes a finished session to disk as human-readable Markdown.
///
/// This is the one deliberate exception to the build's "ephemeral by design"
/// rule: when a session ends we keep a record of the real-time transcript
/// (including user-authored notes, which live inline as `speakerId == "note"`
/// entries), the chat log with the assistant, and session-local audio legs used
/// only by the narrow Upgrade Transcript workflow.
///
/// Layout: <sessions_dir>/<yyyy-MM-dd HHmmss>/ (`sessions_dir` in RTI's
/// config, `~/.config/rti/config.json`; default
/// ~/Documents/Work/Inner-Chapter/meetings/sessions):
///   transcript.md         — the live transcript, notes inline
///   chat.md               — the assistant chat log (only written if non-empty)
///   notes.md              — generated meeting notes (only if any)
///   screen-context.md     — timestamped active-screen OCR changes (only if any)
///   audio-mic.wav         — retained mic audio for automatic transcript upgrade
///   audio-system.wav      — retained system audio for automatic transcript upgrade
///   session.json, speaker-names.json, frames/: metadata, names, screen frames
enum SessionArchive {
    typealias ArchiveMetadata = SessionArchiveMetadata

    struct CanonicalMeetingExport {
        let transcriptURL: URL
        let sidecarURL: URL?
    }

    private static let automaticUpgradeMarker = "automatic-upgrade.pending"

    @discardableResult
    static func markAutomaticUpgradePending(in dir: URL) -> Bool {
        writeOwnerOnly(ISO8601DateFormatter().string(from: Date()), to: dir.appendingPathComponent(automaticUpgradeMarker))
    }

    @discardableResult
    static func seedTranscriptForAutomaticUpgrade(in dir: URL, startedAt: Date) -> Bool {
        let url = dir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: url.path) {
            guard isRegularFile(url), FileManager.default.isReadableFile(atPath: url.path) else {
                RTILog.log("Recovery transcript is not a readable file: \(url.path)", level: .error, category: .archive)
                return false
            }
            return true
        }
        let body = (frontmatter(kind: "Transcript", startedAt: startedAt) + [
            "# Transcript",
            "",
            "_Recording recovered from retained audio._",
            "",
        ]).joined(separator: "\n")
        return writeOwnerOnly(body, to: url)
    }

    @discardableResult
    static func clearAutomaticUpgradePending(in dir: URL) -> Bool {
        let marker = dir.appendingPathComponent(automaticUpgradeMarker)
        guard FileManager.default.fileExists(atPath: marker.path) else { return true }
        guard isRegularFile(marker) else { return false }
        do {
            try FileManager.default.removeItem(at: marker)
            return true
        } catch {
            RTILog.log("Could not clear automatic processing marker: \(error.localizedDescription)", level: .error, category: .archive)
            return false
        }
    }

    static func pendingAutomaticUpgrades() -> [ArchivedSession] {
        // Recovery is not a Recent-sessions view: an older interrupted job
        // must not disappear just because newer sessions were recorded.
        recentSessions(limit: .max).filter {
            $0.isRTIArchive
                && $0.date != nil
                && FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(automaticUpgradeMarker).path)
                && !TranscriptUpgradeAudioDiscovery.inputs(in: $0.url).isEmpty
                && recordingError(in: $0.url) == nil
        }
    }

    static func recordingError(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
              let metadata = try? JSONDecoder().decode(ArchiveMetadata.self, from: data) else { return nil }
        return metadata.recordingError
    }

    /// Persist a session. Returns its directory only when every required
    /// text, metadata, and retained-audio artifact was saved. A failure is
    /// logged and returns nil, so the caller can retain the snapshot for retry.
    /// An empty session also returns nil without writing anything.
    /// F6: one failed file does not stop the others. Every file that can be
    /// written is written from this snapshot (so notes.md, chat.md and
    /// session.json never stay at an older checkpoint behind one blocked
    /// file), and the nil return still says the archive is incomplete.
    /// Only session.json waits for the audio: it never names a leg that was
    /// not staged.
    /// `workstreamSlug` is a pure DECLARATION stamped into frontmatter —
    /// routing policy lives in the `/meeting` skill, never in this app.
    @discardableResult
    static func write(
        startedAt: Date,
        endedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        visualContext: [VisualContextEvent] = [],
        notes: [GeneratedNote] = [],
        sessionId: String? = nil,
        micRecordingURL: URL? = nil,
        systemRecordingURL: URL? = nil,
        systemAudioStartOffsetMs: Int? = nil,
        workstreamSlug: String? = nil,
        mode: String? = nil,
        workstreamName: String? = nil,
        speakerNames: [String: String] = [:],
        speakerAssignments: [String: GuideSpeakerAssignment] = [:],
        calendarTitle: String? = nil,
        speechContext: SonioxContext? = nil,
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0,
        recordingError: String? = nil,
        captureGaps: [CaptureGap] = [],
        guide: GuideArchiveSnapshot? = nil,
        evidence: SessionEvidence? = nil,
        speakerPolicy: SessionSpeakerPolicy? = nil,
        packageRevision: String? = nil
    ) -> URL? {
        let hasRetainedAudio = [micRecordingURL, systemRecordingURL]
            .compactMap { $0 }
            .contains { isRegularFile($0) }
        let expectsAudio = micRecordingURL != nil || systemRecordingURL != nil
        // A live session's write (it carries evidence) or a placed system leg
        // is recovery state even before anyone speaks: without session.json a
        // crash recovers the system leg at offset 0 with no speech context.
        let recoveryState = evidence != nil || systemAudioStartOffsetMs != nil
        guard guide != nil || !transcript.isEmpty || !chat.isEmpty || !notes.isEmpty || !visualContext.isEmpty || !chatThreads.isEmpty || unreadableChatCount > 0 || expectsAudio || recoveryState else { return nil }
        guard let dir = sessionDirectory(startedAt: startedAt) else { return nil }

        func fm(_ kind: String) -> [String] {
            frontmatter(kind: kind, startedAt: startedAt, workstreamSlug: workstreamSlug)
        }
        var complete = true

        // User-authored notes are content too, even before the first spoken
        // word. Retained audio also needs a transcript target for recovery.
        if !transcript.isEmpty || hasRetainedAudio || guide != nil {
            let body = guide == nil
                ? renderTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript, selfName: speakerNames["self"],
                                   captureGaps: captureGaps)
                : renderGuideTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript, captureGaps: captureGaps)
            let md = (fm("Transcript") + [body]).joined(separator: "\n")
            let transcriptURL = dir.appendingPathComponent("transcript.md")
            if !writeOwnerOnly(md, to: transcriptURL) {
                complete = false
            } else if guide != nil || evidence != nil {
                do {
                    try preserveGuideTranscript(transcriptURL)
                } catch {
                    RTILog.log("Could not preserve Guide transcript: \(error.localizedDescription)", level: .error, category: .archive)
                    complete = false
                }
            }
        }

        if let evidence {
            do {
                try evidence.write(in: dir)
                let segments = evidence.turns.map {
                    TranscriptUpgradeSegment(speaker: SpeakerLabelMapping.displayLabel(forRawKey: $0.rawSpeaker) ?? $0.rawSpeaker,
                                             startMs: $0.liveStartMs, text: $0.original)
                }
                let annotated = evidence.transcript(segments: segments, raw: false)
                if !annotated.isEmpty,
                   !writeOwnerOnly((fm("Transcript") + ["# Transcript", ""] + headerLines(startedAt: startedAt, endedAt: endedAt, captureGaps: captureGaps) + [annotated]).joined(separator: "\n"),
                                   to: dir.appendingPathComponent("transcript.md")) {
                    complete = false
                }
            } catch {
                RTILog.log("Could not save transcript evidence: \(error.localizedDescription)", level: .error, category: .archive)
                complete = false
            }
        }

        // Serialize keyed by display labels ("Remote speaker 1"), not raw ids
        // (`remote_1`): the post-hoc rename UI and the `/meeting` skill
        // match names against the labels transcripts actually print.
        let speakerArchive = SpeakerNameArchive(names: speakerNames, assignments: speakerAssignments)
        if !speakerArchive.isEmpty || guide != nil {
            do {
                let data = try JSONEncoder().encode(speakerArchive)
                if !writeOwnerOnly(String(decoding: data, as: UTF8.self), to: dir.appendingPathComponent("speaker-names.json")) {
                    complete = false
                }
            } catch {
                RTILog.log("Could not encode speaker-names.json: \(error.localizedDescription)", level: .error, category: .archive)
                complete = false
            }
        }

        // Structured threads are the authority when the recording has any:
        // every one of them is projected with its exact thread and turn ids, so
        // a recording that held several chats keeps all of them. The flat dated
        // list is used only when there are no structured threads at all, and it
        // never invents boundaries between them.
        if !writeChat(in: dir, startedAt: startedAt, endedAt: endedAt, chat: chat, chatThreads: chatThreads,
                      unreadableChatCount: unreadableChatCount, workstreamSlug: workstreamSlug) {
            complete = false
        }

        if !writeNotes(in: dir, startedAt: startedAt, endedAt: endedAt, notes: notes, workstreamSlug: workstreamSlug) {
            complete = false
        }
        // Frames staged during the session (local-vision lane) move into
        // `frames/` beside screen-context.md; gitignored, owner-only.
        let staging = VisualFrameStore.stagingDirectory(
            configHome: VaultPaths.homeDirectory(),
            startedAt: startedAt
        )
        let movedFrames = VisualFrameStore.promoteStagedFrames(stagingDirectory: staging, into: dir)
        if movedFrames > 0 {
            RTILog.log("Archived \(movedFrames) screen frame(s) into \(dir.lastPathComponent)/frames.", category: .screenshot)
        }
        if !visualContext.isEmpty {
            let body = (["# Screen context", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderVisualContext(visualContext, archive: dir, startedAt: startedAt)]).joined(separator: "\n")
            let md = (fm("Screen context") + [body]).joined(separator: "\n")
            if !writeOwnerOnly(md, to: dir.appendingPathComponent("screen-context.md")) { complete = false }
        }
        let micName = stageRecordingIfPresent(micRecordingURL, as: "audio-mic.wav", in: dir)
        let systemName = stageRecordingIfPresent(systemRecordingURL, as: "audio-system.wav", in: dir)
        // A leg that was not staged keeps its earlier session.json: a new one
        // would drop the audio file name the upgrade and recovery read.
        let audioStaged = (micRecordingURL == nil || micName != nil) && (systemRecordingURL == nil || systemName != nil)
        var guidePath = guide?.guidePath
        var guideSourcePath: String?
        if let guide {
            do {
                if let json = guide.parsedSourceJSON {
                    let file = dir.appendingPathComponent("dg-questions.json")
                    try writeGuideData(json, to: file)
                    guidePath = file.path
                    guideSourcePath = guide.guidePath
                }
                try saveGuideExtraction(guide.extraction, in: dir)
            } catch {
                RTILog.log("Could not save Guide files: \(error.localizedDescription)", level: .error, category: .archive)
                complete = false
            }
        }
        guard audioStaged else { return nil }
        var metadata = ArchiveMetadata(
                sessionId: sessionId,
                systemAudioStartOffsetMs: systemAudioStartOffsetMs,
                micAudioFile: micName,
                systemAudioFile: systemName,
                mode: mode,
                workstream: workstreamName,
                durationSeconds: Int(max(0, endedAt.timeIntervalSince(startedAt))),
                calendarTitle: calendarTitle,
                recordingError: recordingError,
                speechContext: speechContext,
                groupID: guide?.extraction.group,
                guidePath: guidePath,
                guideSourcePath: guideSourcePath,
                rosterPath: guide?.rosterPath,
                guideRoster: guide?.roster
            )
        metadata.speakerPolicy = speakerPolicy
        metadata.captureGaps = captureGaps.isEmpty ? nil : captureGaps
        if let evidence {
            metadata.schemaVersion = evidence.schemaVersion
            if isRegularFile(dir.appendingPathComponent("soniox-live.jsonl")) {
                metadata.liveTokenJournal = "soniox-live.jsonl"
            }
            metadata.evidenceFile = SessionEvidence.filename
            metadata.noteIDs = evidence.notes.map(\.id)
            metadata.markerSpans = evidence.spans
            metadata.turns = evidence.turns
            metadata.stimulusPackageRevision = packageRevision
        }
        guard writeMetadata(metadata, to: dir), complete else { return nil }
        return dir
    }

    /// Write `chat.md` alone. Also used after Stop, when an answer that was
    /// still streaming at Stop is filed (`LateChatArchiveRefresher`); every
    /// other archive file is left as it is. True when nothing needed writing.
    static func writeChat(
        in dir: URL,
        startedAt: Date,
        endedAt: Date,
        chat: [ChatEntry],
        chatThreads: [ChatProjectionMarkdown.Thread],
        unreadableChatCount: Int,
        workstreamSlug: String?
    ) -> Bool {
        let fm = frontmatter(kind: "Chat", startedAt: startedAt, workstreamSlug: workstreamSlug)
        if !chatThreads.isEmpty || (chat.isEmpty && unreadableChatCount > 0) {
            let body = ChatProjectionMarkdown.render(
                threads: chatThreads,
                startedAt: startedAt,
                endedAt: endedAt,
                unreadableChats: unreadableChatCount,
                header: header(startedAt: startedAt, endedAt: endedAt)
            )
            return writeOwnerOnly((fm + [body]).joined(separator: "\n"), to: dir.appendingPathComponent("chat.md"))
        } else if !chat.isEmpty {
            let body = renderChat(startedAt: startedAt, endedAt: endedAt, entries: chat)
            var lines = [body]
            if unreadableChatCount > 0 {
                lines.append("")
                lines.append("_\(unreadableChatCount) stored chat\(unreadableChatCount == 1 ? "" : "s") in this recording could not be read and \(unreadableChatCount == 1 ? "is" : "are") not shown here. Nothing was removed._")
            }
            return writeOwnerOnly((fm + lines).joined(separator: "\n"), to: dir.appendingPathComponent("chat.md"))
        }
        return true
    }

    /// Write `notes.md` alone. Also used after Stop, when a notes block lands
    /// after the archive was written (`LateChatArchiveRefresher`). True when
    /// nothing needed writing.
    static func writeNotes(in dir: URL, startedAt: Date, endedAt: Date, notes: [GeneratedNote], workstreamSlug: String?) -> Bool {
        guard !notes.isEmpty else { return true }
        let body = (["# Notes", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderNotes(notes)]).joined(separator: "\n")
        let md = (frontmatter(kind: "Notes", startedAt: startedAt, workstreamSlug: workstreamSlug) + [body]).joined(separator: "\n")
        return writeOwnerOnly(md, to: dir.appendingPathComponent("notes.md"))
    }

    /// Export RTI's live transcript into the raw-transcript lane
    /// (`meetings/transcripts-raw/`), where the `/meeting` skill turns it into
    /// the canonical meeting note.
    /// This copies out of the RTI archive; it does not move or delete the archive.
    @discardableResult
    static func writeCanonicalMeetingExport(
        startedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        callType: CallType
    ) -> CanonicalMeetingExport? {
        let raw = CanonicalMeetingTranscript.render(entries: transcript)
        return writeCanonicalMeetingExport(
            startedAt: startedAt,
            rawTranscript: raw,
            chat: chat,
            visualContext: visualContext,
            notes: notes,
            archiveDir: archiveDir,
            callType: callType
        )
    }

    /// Native archives project the same provider-derived evidence as the
    /// in-app transcript. Historical archives retain their Markdown adapter.
    @discardableResult
    static func refreshCanonicalMeetingTranscript(fromArchiveDir archiveDir: URL, startedAt: Date) -> URL? {
        let raw: String
        let native = ["soniox-async-mic.json", "soniox-async-system.json"].contains {
            isRegularFile(archiveDir.appendingPathComponent($0))
        }
        if native {
            guard let evidence = try? SessionEvidence.read(in: archiveDir), let upgraded = evidence.upgradedTurns else { return nil }
            let turns = upgraded.map {
                TranscriptUpgradeSegment(speaker: $0.speaker, startMs: $0.playbackStartMs, text: $0.text, source: $0.providerSource)
            }
            raw = evidence.transcript(segments: turns, raw: true)
        } else {
            let transcriptURL = archiveDir.appendingPathComponent("transcript.md")
            guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
            let tracked = FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent(SessionEvidence.filename).path)
            raw = tracked ? SessionEvidence.raw(from: markdown) : CanonicalMeetingTranscript.render(markdownTranscript: markdown)
        }
        return writeCanonicalMeetingExport(
            startedAt: startedAt,
            rawTranscript: raw,
            chat: [],
            visualContext: [],
            notes: [],
            archiveDir: archiveDir,
            writeSidecar: false
        )?.transcriptURL
    }

    static func requiredCanonicalExport(in archive: URL, startedAt: Date) throws -> URL? {
        // No meetings folder is a failure, never a quiet success: the caller
        // would clear the upgrade marker and /meeting would never run.
        guard let raw = meetingTranscriptsRawDirectory() else {
            throw TranscriptUpgradeError.writeFailed(missingTranscriptsFolderMessage())
        }
        guard let url = refreshCanonicalMeetingTranscript(fromArchiveDir: archive, startedAt: startedAt) else {
            throw TranscriptUpgradeError.writeFailed("The upgraded transcript is saved. Could not write the raw transcript in " + raw.path)
        }
        // Any current-format session gets a sidecar, even one that died
        // before its first archive write: its typed notes sit in the marker
        // journal. Historical archives (none of these files) get none.
        let tracked = [SessionEvidence.filename, SessionMarkerJournal.filename, SonioxLiveJournal.filename].contains {
            FileManager.default.fileExists(atPath: archive.appendingPathComponent($0).path)
        }
        if tracked {
            let sidecar = raw.appendingPathComponent(canonicalMeetingStem(startedAt: startedAt) + "-rti.md")
            if !isRegularFile(sidecar) {
                let mode = (try? readMetadata(in: archive))?.mode
                let type = CallType.allCases.first { $0.name == mode } ?? .client
                // Stop never finished (a crash, or a quit before the
                // emergency write): carry what the archive itself kept.
                guard writeCanonicalMeetingSidecar(startedAt: startedAt, chat: [], visualContext: [], notes: [],
                                                   archiveDir: archive, callType: type,
                                                   archivedSections: archivedSidecarSections(in: archive)) != nil else {
                    throw TranscriptUpgradeError.writeFailed("The upgraded transcript is saved. Could not write " + sidecar.path)
                }
            }
        }
        return url
    }

    /// Transcripts with a `/meeting` run still alive. A second run on the
    /// same transcript would race the first on its note and on the memory
    /// repo's commit and push.
    private static let runningMeetingProcessors = OSAllocatedUnfairLock(initialState: Set<String>())

    static func runMeetingProcessor(transcriptURL: URL) {
        guard MeetingProcessorConfig.isEnabled(config: appConfig()) else {
            RTILog.log("meeting processor: auto_process is off; skipped \(transcriptURL.lastPathComponent)", category: .archive)
            return
        }
        guard let claude = ExternalTools.claude() else {
            RTILog.log("meeting processor: claude CLI not found; skipped \(transcriptURL.lastPathComponent)", category: .archive)
            return
        }
        let key = transcriptURL.standardizedFileURL.path
        guard runningMeetingProcessors.withLock({ $0.insert(key).inserted }) else {
            RTILog.log("meeting processor: already running for \(transcriptURL.lastPathComponent); skipped", category: .archive)
            return
        }
        let workdir = MeetingProcessorConfig.workingDirectory()
        let prompt = meetingProcessorPrompt(transcriptURL: transcriptURL)
        let args = MeetingProcessorConfig.permissionArguments(config: appConfig())

        let logURL = meetingProcessorLogURL(stem: transcriptURL.deletingPathExtension().lastPathComponent)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)

        let proc = Process()
        proc.executableURL = claude
        proc.currentDirectoryURL = workdir
        proc.arguments = ["-p", prompt] + args
        proc.standardInput = FileHandle.nullDevice
        if let logHandle {
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        }
        let name = transcriptURL.lastPathComponent
        proc.terminationHandler = { finished in
            _ = runningMeetingProcessors.withLock { $0.remove(key) }
            try? logHandle?.close()
            if let line = MeetingProcessorConfig.exitLogLine(
                name: name, status: finished.terminationStatus, reason: finished.terminationReason
            ) {
                RTILog.log(line, category: .archive)
            }
        }
        do {
            try proc.run()
            RTILog.log("meeting processor started for \(transcriptURL.lastPathComponent)", category: .archive)
        } catch {
            _ = runningMeetingProcessors.withLock { $0.remove(key) }
            try? logHandle?.close()
            RTILog.log("meeting processor failed to start: \(error.localizedDescription)", category: .archive)
        }
    }

    /// Persist RTI chat and screen context beside the eventual canonical transcript
    /// without writing a provisional raw transcript. The upgraded transcript
    /// remains the only text eligible for downstream meeting processing.
    @discardableResult
    static func writeCanonicalMeetingSidecar(
        startedAt: Date,
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        callType: CallType,
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0,
        typedNotes: [LiveEntry] = [],
        archivedSections: [String] = []
    ) -> URL? {
        guard let transcriptsRaw = meetingTranscriptsRawDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: transcriptsRaw, withIntermediateDirectories: true)
        let stem = canonicalMeetingStem(startedAt: startedAt)
        let sidecar = renderCanonicalSidecar(
            stem: stem,
            startedAt: startedAt,
            chat: chat,
            visualContext: visualContext,
            notes: notes,
            archiveDir: archiveDir,
            callType: callType,
            chatThreads: chatThreads,
            unreadableChatCount: unreadableChatCount,
            typedNotes: typedNotes,
            archivedSections: archivedSections
        )
        guard !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url = transcriptsRaw.appendingPathComponent("\(stem)-rti.md")
        return writeOwnerOnly(sidecar, to: url) ? url : nil
    }

    @discardableResult
    private static func writeCanonicalMeetingExport(
        startedAt: Date,
        rawTranscript: String,
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        callType: CallType? = nil,
        writeSidecar: Bool = true
    ) -> CanonicalMeetingExport? {
        let text = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let transcriptsRaw = meetingTranscriptsRawDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: transcriptsRaw, withIntermediateDirectories: true)

        let stem = canonicalMeetingStem(startedAt: startedAt)
        let transcriptURL = transcriptsRaw.appendingPathComponent("\(stem)-transcript.txt")
        guard writeOwnerOnly(text + "\n", to: transcriptURL) else { return nil }

        let sidecarURL: URL?
        if writeSidecar, let callType {
            let sidecar = renderCanonicalSidecar(
                stem: stem,
                startedAt: startedAt,
                chat: chat,
                visualContext: visualContext,
                notes: notes,
                archiveDir: archiveDir,
                callType: callType
            )
            if sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidecarURL = nil
            } else {
                let url = transcriptsRaw.appendingPathComponent("\(stem)-rti.md")
                guard writeOwnerOnly(sidecar, to: url) else { return nil }
                sidecarURL = url
            }
        } else {
            sidecarURL = nil
        }

        RTILog.log("canonical meeting transcript exported: \(transcriptURL.path)", category: .archive)
        return CanonicalMeetingExport(transcriptURL: transcriptURL, sidecarURL: sidecarURL)
    }

    /// The user-facing reason no meetings folder could be found.
    static func missingTranscriptsFolderMessage() -> String {
        let cause = VaultPaths.configReadProblem()
            ?? "\(VaultPaths.configURL().path) names no transcripts_dir, knowledge_base_dir or recordings_dir."
        return "The upgraded transcript is saved, but RTI could not find the meetings folder, so /meeting has not run. "
            + cause + " RTI tries again at next launch."
    }

    static func meetingTranscriptsRawDirectory() -> URL? {
        if let transcriptsRaw = VaultPaths.meetingTranscriptsRawDirectory() { return transcriptsRaw }
        return VaultLogStore.rtiDirectory()?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("meetings/transcripts-raw", isDirectory: true)
    }

    private static func canonicalMeetingStem(startedAt: Date) -> String {
        "rti-session-\(canonicalStamp.string(from: startedAt))"
    }

    private static func renderCanonicalSidecar(
        stem: String,
        startedAt: Date,
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        callType: CallType,
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0,
        typedNotes: [LiveEntry] = [],
        archivedSections: [String] = []
    ) -> String {
        var lines = [
            "---",
            "source: rti-live",
            callType.sidecarField,
            "meeting: \(yamlQuoted(stem))",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
        ]
        if let archiveDir,
           let metadata = try? readMetadata(in: archiveDir),
           let guidePath = metadata.guidePath {
            lines.append("archive_dir: \(yamlQuoted(archiveDir.path))")
            lines.append("guide_path: \(yamlQuoted(guidePath))")
            if let source = metadata.guideSourcePath { lines.append("guide_source_path: \(yamlQuoted(source))") }
            if let group = metadata.groupID { lines.append("group_id: \(yamlQuoted(group))") }
            if let path = metadata.rosterPath { lines.append("roster_path: \(yamlQuoted(path))") }
        }
        if let archiveDir {
            if FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent(SessionEvidence.filename).path) {
                lines.append("transcript_evidence: " + yamlQuoted(archiveDir.appendingPathComponent(SessionEvidence.filename).path))
                lines.append("session_metadata: " + yamlQuoted(archiveDir.appendingPathComponent("session.json").path))
            }
            if FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent(SessionMarkerJournal.filename).path) {
                lines.append("note_journal: " + yamlQuoted(archiveDir.appendingPathComponent(SessionMarkerJournal.filename).path))
            }
            lines += ResearchCodebookStore.sidecarFields(in: archiveDir)
        }
        lines += ["---", "", "# RTI live notes — \(stem)", "", "_Canonical transcript: `\(stem)-transcript.txt`_"]
        if let archiveDir {
            lines.append("_RTI archive: `\(archiveDir.path)`_")
        }
        lines.append("")

        // Stretches a leg did not record, before anything else /meeting reads.
        if let archiveDir, let gaps = (try? readMetadata(in: archiveDir))?.captureGaps, !gaps.isEmpty {
            lines += ["## Recording gaps", ""] + CaptureGapLog.markdown(gaps) + [""]
        }
        // Notes the user typed during the call; the canonical transcript drops them.
        if let archiveDir, let journal = try? SessionMarkerJournal.read(in: archiveDir), !journal.isEmpty {
            lines += ["## My notes and markers", ""]
            for note in MarkerTimeline(events: journal).entries {
                lines += ["- \(GuideExtraction.locator(note.offsetMs)) · \(note.kind.rawValue) · " + note.label.replacingOccurrences(of: "\n", with: "\n  ")]
            }
            lines.append("")
        } else if !typedNotes.isEmpty {
            lines += ["## My notes", ""] + typedNotes.map { "- " + $0.text.replacingOccurrences(of: "\n", with: " ") } + [""]
        }
        if !notes.isEmpty {
            lines.append("## Generated notes")
            lines.append("")
            lines.append(renderNotes(notes))
            lines.append("")
        }
        if !visualContext.isEmpty {
            lines.append("## Screen context")
            lines.append("")
            lines.append(renderVisualContext(visualContext, archive: archiveDir, startedAt: startedAt))
            lines.append("")
        }
        // The same rule as chat.md: structured threads win, and the dated list
        // is only for a recording that has none.
        if !chatThreads.isEmpty || unreadableChatCount > 0 {
            lines += ChatProjectionMarkdown.renderSection(
                threads: chatThreads,
                unreadableChats: unreadableChatCount
            )
        } else if !chat.isEmpty {
            lines.append("## Assistant chat")
            lines.append("")
            lines += chatBlock(chat)
        }
        for section in archivedSections {
            lines += [section, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// The sidecar sections a session folder can still supply when Stop never
    /// wrote the sidecar: the generated notes, the screen context and the chat
    /// from its last archive write, each without its file's frontmatter, title
    /// and date line.
    static func archivedSidecarSections(in archive: URL) -> [String] {
        [("notes.md", "## Generated notes"), ("screen-context.md", "## Screen context"), ("chat.md", "## Assistant chat")]
            .compactMap { file, heading in
                guard let text = try? String(contentsOf: archive.appendingPathComponent(file), encoding: .utf8) else { return nil }
                let body = archivedBody(text)
                return body.isEmpty ? nil : heading + "\n\n" + body
            }
    }

    /// An archive file's body: the frontmatter, the `# Title` line and the
    /// `_date · duration_` line removed.
    private static func archivedBody(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")[...]
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines = lines[(close + 1)...]
        }
        func dropBlank() { while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines = lines.dropFirst() } }
        dropBlank()
        if let first = lines.first, first.hasPrefix("# ") { lines = lines.dropFirst() }
        dropBlank()
        if let first = lines.first, first.hasPrefix("_"), first.hasSuffix("_") { lines = lines.dropFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meetingProcessorPrompt(transcriptURL: URL) -> String {
        let template = appConfig()["auto_process_prompt"] as? String
            ?? defaultMeetingProcessorPrompt
        return template.replacingOccurrences(of: "{transcript}", with: transcriptURL.path)
    }

    private static func appConfig() -> [String: Any] {
        VaultPaths.configDictionary()
    }

    /// The headless /meeting processor's log for a session started at the
    /// given time — surfaced as the per-session "Log" pill in the browser.
    /// The processor logs under the exported transcript's stem, which carries
    /// a "-transcript" suffix (see runMeetingProcessor's caller).
    static func processingLogURL(forSessionStartedAt startedAt: Date) -> URL {
        meetingProcessorLogURL(stem: canonicalMeetingStem(startedAt: startedAt) + "-transcript")
    }

    private static func meetingProcessorLogURL(stem: String) -> URL {
        AppLog.logsDirectory
            .appendingPathComponent("meeting-process-\(stem).log")
    }

    private static let workRoot = NSHomeDirectory() + "/Documents/Work"

    private static let defaultMeetingProcessorPrompt = """
    Read \(NSHomeDirectory())/skills/meeting/SKILL.md and its references/method.md, then follow that skill for this transcript: {transcript}

    IMPORTANT: this run is UNATTENDED (fired automatically after an RTI recording), so be conservative. (1) Always write the meeting note. (2) File it in a project only when you are confident which existing project under \(workRoot) it belongs to. (3) Never create a project folder, never send anything, never edit client shared files. (4) If the project is new, ambiguous or unsure, leave the note unrouted in \(workRoot)/Inner-Chapter/meetings with 'projects: [unsorted]' and a '## Needs routing' section giving your best guess and why. Never guess a project into existence.
    """

    static func sessionDirectory(startedAt: Date) -> URL? {
        guard let base = sessionsBaseDirectory() else { return nil }
        let folder = base.appendingPathComponent(folderStamp.string(from: startedAt), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Session records hold meeting transcripts/notes — keep the folder
            // unreadable by other users on a shared Mac.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            RTILog.log("Could not create session archive \(folder.path): \(error.localizedDescription)", level: .error, category: .archive)
            return nil
        }
        return folder
    }

    /// Write `string` atomically, then restrict the file to owner-only (0600).
    /// Used for every session-record file (transcript/chat/notes/etc.) so
    /// meeting content isn't world-readable on a multi-user machine.
    @discardableResult
    private static func writeOwnerOnly(_ string: String, to url: URL) -> Bool {
        do {
            try string.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            RTILog.log("Could not save \(url.path): \(error.localizedDescription)", level: .error, category: .archive)
            return false
        }
    }

    /// Move retained audio without replacing an earlier recording. A collision
    /// leaves both files in place and fails the archive, so neither copy is lost.
    /// Checkpoints pass no source: keep the name of any audio already in place.
    private static func stageRecordingIfPresent(_ sourceURL: URL?, as fileName: String, in dir: URL) -> String? {
        let destination = dir.appendingPathComponent(fileName)
        guard let sourceURL else { return isRegularFile(destination) ? fileName : nil }
        guard isRegularFile(sourceURL) else {
            RTILog.log("Retained audio is missing or is not a file: \(sourceURL.path)", level: .error, category: .archive)
            return nil
        }
        if sourceURL.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() { return fileName }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            RTILog.log("Retained audio collision; both recordings were kept: \(destination.path)", level: .error, category: .archive)
            return nil
        }
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return fileName
        } catch {
            RTILog.log("Could not retain audio \(sourceURL.path): \(error.localizedDescription)", level: .error, category: .archive)
            return nil
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func writeMetadata(_ metadata: ArchiveMetadata, to dir: URL) -> Bool {
        let url = dir.appendingPathComponent("session.json")
        do {
            let data = try JSONEncoder().encode(metadata)
            return writeOwnerOnly(String(decoding: data, as: UTF8.self), to: url)
        } catch {
            RTILog.log("Could not encode session.json: \(error.localizedDescription)", level: .error, category: .archive)
            return false
        }
    }

    private static func readMetadata(in directory: URL) throws -> ArchiveMetadata {
        try JSONDecoder().decode(ArchiveMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }

    private static func saveGuideExtraction(_ extraction: GuideExtraction, in directory: URL) throws {
        let url = directory.appendingPathComponent(extraction.fileName)
        try writeGuideJSON(extraction, to: url)
    }

    private static func writeGuideJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeGuideData(encoder.encode(value), to: url)
    }

    /// Set permissions before the atomic replacement. A permission error after
    /// a committed speaker edit would otherwise roll back only its cells.
    private static func writeGuideData(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".guide-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @MainActor
    static func updateGuideSpeakers(in directory: URL, archive: SpeakerNameArchive) throws {
        let metadata = try readMetadata(in: directory)
        guard let group = metadata.groupID, metadata.guidePath != nil else { throw CocoaError(.fileReadCorruptFile) }
        let cellsURL = directory.appendingPathComponent(GuideExtraction.fileName(for: group))
        let previous = try Data(contentsOf: cellsURL)
        var extraction = try JSONDecoder().decode(GuideExtraction.self, from: previous)
        guard extraction.group == group else { throw CocoaError(.fileReadCorruptFile) }
        let count = metadata.guideRoster?.count ?? 0
        extraction.remap(speakers: archive.guideSpeakers, rosterBase: count > 0 ? count : nil)
        // Complete both projections on this actor before an upgrade or another editor can run.
        try saveGuideExtraction(extraction, in: directory)
        do {
            try writeGuideJSON(archive, to: directory.appendingPathComponent("speaker-names.json"))
        } catch {
            try writeGuideData(previous, to: cellsURL)
            throw error
        }
    }

    @MainActor
    static func reanchorGuide(in directory: URL, upgradedTurns: [TranscriptUpgradeSegment]) throws {
        let proof = directory.appendingPathComponent("transcript.live.md")
        let metadata: ArchiveMetadata
        if FileManager.default.fileExists(atPath: proof.path) {
            metadata = try readMetadata(in: directory)
        } else {
            // Earlier archives need no Guide metadata. A guided archive missing
            // its proof must keep its live evidence pending for review.
            guard let existing = try? readMetadata(in: directory), existing.guidePath != nil else { return }
            metadata = existing
        }
        guard metadata.guidePath != nil else { return }
        guard let group = metadata.groupID else { throw CocoaError(.fileReadCorruptFile) }
        let url = directory.appendingPathComponent(GuideExtraction.fileName(for: group))
        var extraction = try JSONDecoder().decode(GuideExtraction.self, from: Data(contentsOf: url))
        guard extraction.group == group else { throw CocoaError(.fileReadCorruptFile) }
        let live = try String(contentsOf: proof, encoding: .utf8)
        let liveRemoteTurns = TranscriptUpgradeMerge.liveSegments(from: live, remote: true)
        extraction.reanchor { quote in
            guard quote.rawSpeaker == "remote" || quote.rawSpeaker.hasPrefix("remote_"),
                  let source = TranscriptUpgradeMerge.guideAnchor(original: quote.original.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 liveStartMs: quote.liveStartMs, in: liveRemoteTurns),
                  source.speaker == SpeakerLabelMapping.displayLabel(forRawKey: quote.rawSpeaker),
                  source.startMs / 1000 == quote.liveStartMs / 1000,
                  let match = TranscriptUpgradeMerge.guideAnchor(original: quote.original, liveStartMs: quote.liveStartMs, in: upgradedTurns)
            else { return nil }
            return (match.startMs, match.speaker)
        }
        let timeline = try MarkerTimeline(events: SessionMarkerJournal.read(in: directory))
        if extraction.positions != nil || timeline.entries.contains(where: { $0.kind == .marker && $0.guideQuestionID != nil }) {
            let file = directory.appendingPathComponent("speaker-names.json")
            let archive = FileManager.default.fileExists(atPath: file.path)
                ? try JSONDecoder().decode(SpeakerNameArchive.self, from: Data(contentsOf: file)) : SpeakerNameArchive()
            let positions = extraction.positions ?? []
            let rosterCount = metadata.guideRoster?.count ?? 0
            extraction.refile(speakers: archive.guideSpeakers, rosterBase: rosterCount > 0 ? rosterCount : nil) { ms in
                let marker = timeline.context(at: ms)
                let last = positions.last { $0.ms <= ms }
                if let last, last.manual, last.ms >= (marker.startMs ?? 0) { return last.qid }
                if let linked = marker.guideQuestionID { return linked }
                return last.flatMap { $0.manual || $0.ms > 0 ? $0.qid : nil }
            }
        }
        try saveGuideExtraction(extraction, in: directory)
    }

    /// A stable copy of the live source survives replacement of transcript.md
    /// by the upgraded transcript. Checkpoints replace the link atomically.
    private static func preserveGuideTranscript(_ transcript: URL) throws {
        let directory = transcript.deletingLastPathComponent()
        let destination = directory.appendingPathComponent("transcript.live.md")
        let temporary = directory.appendingPathComponent(".guide-transcript-\(UUID().uuidString)")
        let manager = FileManager.default
        do {
            try manager.linkItem(at: transcript, to: temporary)
        } catch {
            // Some session folders are on filesystems without hard links.
            try manager.copyItem(at: transcript, to: temporary)
        }
        defer { try? manager.removeItem(at: temporary) }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private static func renderGuideTranscript(startedAt: Date, endedAt: Date, entries: [LiveEntry], captureGaps: [CaptureGap] = []) -> String {
        var rows = GuideTranscript.sources(from: entries).map { source in
            let turn = source.turn
            return (turn.startMs, SpeakerLabelMapping.displayLabel(forRawKey: turn.speaker) ?? turn.speaker, turn.text)
        }
        rows.append(contentsOf: entries.filter { $0.speakerId == "note" }.map { ($0.startMs, "📝 Note", $0.text) })
        var lines = ["# Transcript", ""] + headerLines(startedAt: startedAt, endedAt: endedAt, captureGaps: captureGaps)
        for (ms, speaker, text) in rows.sorted(by: { $0.0 < $1.0 }) {
            let stamp = GuideExtraction.locator(ms) + String(format: ".%03d", max(0, ms) % 1000)
            lines += ["`\(stamp)` **\(speaker):** \(text)", ""]
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering

    static func renderTranscript(startedAt: Date, endedAt: Date, entries: [LiveEntry], selfName: String? = nil,
                                 captureGaps: [CaptureGap] = []) -> String {
        var lines = ["# Transcript", ""] + headerLines(startedAt: startedAt, endedAt: endedAt, captureGaps: captureGaps)

        // Originals only — live-translation tokens are a viewing convenience, not
        // part of the kept record.
        let sorted = entries
            .filter { $0.translationStatus != "translation" }
            .sorted { $0.startMs < $1.startMs }

        // Leg-aware labels from the speaker id, never renumbered by who spoke
        // first: `You`, `Room speaker N` (mic), `Remote speaker N` (system).
        // They are the keys of speaker-names.json, so names stay out of
        // this file: the Sessions browser and /meeting apply them from
        // speaker-names.json. (Printing appearance-ordered "Speaker N" with
        // names substituted left the names file matching no label, sent
        // remote voices to the mic WAV, and gave enrollment no turns.)
        // One exception: a name given to `self` is printed here. It is on the
        // mic leg, so the leg rule still holds, and speaker-names.json never
        // carries `self` (a "You" key would rewrite ordinary prose), so this
        // file is the only place a renamed mic wearer is kept.
        let selfName = selfName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func label(for id: String) -> String {
            if id == "note" { return "📝 Note" }
            if id == "self", !selfName.isEmpty { return selfName }
            return SpeakerLabelMapping.displayLabel(forRawKey: id) ?? id
        }

        // Coalesce a speaker's consecutive fragments into one flowing paragraph,
        // timestamped at the start of the run. Notes stay on their own line.
        var runSpeaker: String?
        var runStartMs = 0
        var buffer = ""
        func flush() {
            guard let speaker = runSpeaker, !buffer.isEmpty else { return }
            lines.append("`\(offset(runStartMs))` **\(label(for: speaker)):** \(buffer)")
            lines.append("")
        }

        for entry in sorted {
            if entry.speakerId == "note" {
                flush()
                runSpeaker = nil
                buffer = ""
                lines.append("`\(offset(entry.startMs))` **📝 Note:** \(entry.text)")
                lines.append("")
            } else if entry.speakerId == runSpeaker {
                buffer += " " + entry.text
            } else {
                flush()
                runSpeaker = entry.speakerId
                runStartMs = entry.startMs
                buffer = entry.text
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    private static func renderChat(startedAt: Date, endedAt: Date, entries: [ChatEntry]) -> String {
        let lines = ["# Chat", "", header(startedAt: startedAt, endedAt: endedAt), ""] + chatBlock(entries)
        return lines.joined(separator: "\n")
    }

    /// One Markdown block per chat turn, shared by the local archive and the
    /// `-rti.md` sidecar.
    private static func chatBlock(_ entries: [ChatEntry]) -> [String] {
        var lines: [String] = []
        for entry in entries {
            let speaker = entry.role == "assistant" ? "Assistant" : "You"
            var tags: [String] = []
            if let action = entry.action { tags.append(action) }
            if entry.contextUsed { tags.append("transcript") }
            if entry.screenContextUsed { tags.append("screen") }
            let suffix = tags.isEmpty ? "" : " _(\(tags.joined(separator: ", ")))_"
            lines.append("**\(speaker)**\(suffix)")
            lines.append("")
            if !entry.referencedPaths.isEmpty {
                lines.append("Referenced files:")
                for path in entry.referencedPaths {
                    lines.append("- `\(path)`")
                }
                lines.append("")
            }
            lines.append(entry.text)
            lines.append("")
        }
        return lines
    }

    /// Combined markdown for generated notes: one block per note, newest
    /// material last, separated by rules. Shared by the local archive and the
    /// `-rti.md` sidecar.
    private static func renderNotes(_ notes: [GeneratedNote]) -> String {
        notes.map { n in
            var head = "### \(offset(n.rangeStartMs)) – \(offset(n.rangeEndMs))"
            if !n.title.isEmpty { head += " · \(n.title)" }
            return "\(head)\n\n\(n.content)"
        }.joined(separator: "\n\n")
    }

    /// Materially changed active-screen captures. Each event carries its OCR
    /// text, and — when the local-vision lane is enabled — a model description
    /// plus a pointer to the compressed frame kept in the session's `frames/`
    /// directory. The frame files themselves stay out of git and out of the
    /// meeting-note text lane; only these references and text travel.
    private static func renderVisualContext(_ events: [VisualContextEvent], archive: URL?, startedAt: Date) -> String {
        let staging = VisualFrameStore.stagingDirectory(configHome: VaultPaths.homeDirectory(), startedAt: startedAt)
        return events.map { event in
            var lines = ["### `\(VisualContextText.timestamp(event.offsetSeconds))`", ""]
            if let frame = event.frameFilename, !frame.isEmpty {
                let destination = archive?.appendingPathComponent("frames").appendingPathComponent(frame)
                let ready = destination.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    && !FileManager.default.fileExists(atPath: staging.appendingPathComponent(frame).path)
                lines.append(ready ? "_Frame: frames/\(frame)_" : "_Frame awaiting archive: \(frame)_")
                lines.append("")
            }
            lines.append(event.text)
            if let vision = event.visionSummary, !vision.isEmpty {
                lines.append("")
                lines.append("**What the screen looks like:** \(vision)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")
    }

    /// The date line, then the recording-gaps block when a leg missed part
    /// of the call (AUD-4), each followed by a blank line.
    private static func headerLines(startedAt: Date, endedAt: Date, captureGaps: [CaptureGap]) -> [String] {
        let gaps = CaptureGapLog.markdown(captureGaps)
        return [header(startedAt: startedAt, endedAt: endedAt), ""] + (gaps.isEmpty ? [] : gaps + [""])
    }

    private static func header(startedAt: Date, endedAt: Date) -> String {
        let started = headerStamp.string(from: startedAt)
        let seconds = Int(max(0, endedAt.timeIntervalSince(startedAt)))
        return "_\(started) · \(duration(seconds))_"
    }

    /// YAML frontmatter so the vault's Neon ingester titles + links these files.
    /// Must be the very first thing in the file, before the H1. `kind` is the
    /// file's human label, e.g. "Transcript" / "Chat" / "Screen context".
    /// `type: reference` keeps them out of the meeting_note / transcript
    /// buckets the ingester would otherwise infer from the filename.
    private static func frontmatter(
        kind: String,
        startedAt: Date,
        workstreamSlug: String? = nil
    ) -> [String] {
        let stamp = frontmatterStamp.string(from: startedAt) // "2026-06-09 11:07"
        let date = String(stamp.prefix(10)) // "2026-06-09"
        var lines = [
            "---",
            "title: \"RTI session · \(stamp) · \(kind)\"",
            "type: reference",
            "date: \(date)",
            "source: rti",
        ]
        // Declaration: which workstream this session was set up against.
        // Facts only — routing policy lives in the `/meeting` skill.
        if let workstreamSlug, !workstreamSlug.isEmpty {
            lines.append("workstream: \(yamlQuoted(workstreamSlug))")
        }
        lines += [
            "projects:",
            "  - rti",
            "tags:",
            "  - rti",
            "---",
            "",
        ]
        return lines
    }

    static func frontmatterForUpgrade(kind: String, startedAt: Date) -> [String] {
        frontmatter(kind: kind, startedAt: startedAt)
    }

    private static let frontmatterStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Formatting helpers

    /// Milliseconds-since-start → "m:ss" (or "h:mm:ss" past an hour).
    private static func offset(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    private static let canonicalStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let headerStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Escape a string for YAML double-quoted scalars. Backslash, double quote,
    /// and common whitespace escapes are handled so meeting names or slugs that
    /// contain colons, quotes, or newlines cannot corrupt the frontmatter.
    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

// MARK: - Reading the archive (launcher only — reveals in Finder, never reads in-app)

extension SessionArchive {
    struct ArchivedSession: Identifiable, Hashable {
        var id: URL {
            url
        }

        let url: URL
        /// Recorded-meeting rows point directly at the meeting's definitive
        /// transcript. RTI archives point at their per-session directory.
        let transcriptURL: URL
        let isRTIArchive: Bool
        /// Parsed from the `yyyy-MM-dd HHmmss` folder name. Nil if the folder
        /// isn't a recognised stamp (falls back to a flat list under "Earlier").
        let date: Date?
        /// Short title from `title.txt` (a manual rename). Nil when none is
        /// set; the browser then shows "Untitled session".
        let title: String?
        /// Pretty label, e.g. "Jun 8 · 16:13".
        let displayName: String
    }

    /// Base dir for per-session records: `sessions_dir` from RTI's config.
    static func sessionsBaseDirectory() -> URL? {
        VaultPaths.sessionsDirectory()
    }

    /// Recent archived sessions, newest first (folder names are timestamp-
    /// prefixed, so reverse lexicographic = newest-first). Backs a convenience
    /// launcher only — returns folders to reveal in Finder, not content to read.
    static func recentSessions(limit: Int = 10) -> [ArchivedSession] {
        let rtiSessions: [ArchivedSession]
        if let base = sessionsBaseDirectory(),
           let urls = try? FileManager.default.contentsOfDirectory(
                  at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
           ) {
            rtiSessions = urls
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { ArchivedSession(
                    url: $0,
                    transcriptURL: $0.appendingPathComponent("transcript.md"),
                    isRTIArchive: true,
                    date: folderStamp.date(from: $0.lastPathComponent),
                    title: titleFile(at: $0),
                    displayName: prettyName($0.lastPathComponent)
                ) }
        } else {
            rtiSessions = []
        }

        return (rtiSessions + recordedMeetingSessions())
            .sorted {
                ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Legacy recorded meetings (`.meeting.json` sidecars in the vault's
    /// recordings directory) are sessions too, even when RTI live
    /// intelligence was never enabled. Read their sidecars rather than
    /// guessing from loose files, and keep the transcript at its vault
    /// location instead of copying it into RTI's archive.
    static func recordedMeetingSessions(
        configURL: URL = VaultPaths.configURL(),
        fileManager: FileManager = .default
    ) -> [ArchivedSession] {
        VaultPaths.recordedMeetings(configURL: configURL, fileManager: fileManager).map { record in
            let title = genericMeetingName(record.name) ? "Recorded meeting" : record.name
            return ArchivedSession(
                url: record.transcriptURL,
                transcriptURL: record.transcriptURL,
                isRTIArchive: false,
                date: record.startedAt,
                title: title,
                displayName: record.startedAt.map { sessionListStamp.string(from: $0) } ?? record.name
            )
        }
    }

    private static func genericMeetingName(_ name: String) -> Bool {
        name.range(of: #"^meeting-\d{8}-\d{4}$"#, options: .regularExpression) != nil
    }

    /// Read the one-line title in `title.txt` (best-effort:
    /// missing or unreadable ⇒ nil, never throws).
    private static func titleFile(at dir: URL) -> String? {
        let title = (try? String(contentsOf: dir.appendingPathComponent("title.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }

    /// "2026-06-08 161305" → "Jun 8 · 16:13"; falls back to the raw name.
    private static func prettyName(_ folder: String) -> String {
        guard let date = folderStamp.date(from: folder) else { return folder }
        return sessionListStamp.string(from: date)
    }

    private static let sessionListStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}
