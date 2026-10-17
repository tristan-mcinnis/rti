import Foundation
import RTICore

/// Writes a finished session to disk as human-readable Markdown.
///
/// This is the one deliberate exception to the build's "ephemeral by design"
/// rule: when a session ends we keep a record of the real-time transcript
/// (including user-authored notes, which live inline as `speakerId == "note"`
/// entries), the chat log with the assistant, and session-local audio legs used
/// only by the narrow Upgrade Transcript workflow.
///
/// Layout: <vault>/databases/projects/personal/rti/sessions/<yyyy-MM-dd HHmmss>/
/// (falls back to ~/Library/Application Support/RTI/sessions/ if the vault
/// can't be located via RTI's config, `~/.config/rti/config.json`):
///   transcript.md         — the live transcript, notes inline
///   chat.md               — the assistant chat log (only written if non-empty)
///   notes.md              — generated meeting notes (only if any)
///   screen-context.md     — timestamped active-screen OCR changes (only if any)
///   audio-mic.wav         — retained mic audio for automatic transcript upgrade
///   audio-system.wav      — retained system audio for automatic transcript upgrade
enum SessionArchive {
    typealias ArchiveMetadata = SessionArchiveMetadata

    struct CanonicalMeetingExport {
        let transcriptURL: URL
        let sidecarURL: URL?
    }

    private static let automaticUpgradeMarker = "automatic-upgrade.pending"

    static func markAutomaticUpgradePending(in dir: URL) {
        writeOwnerOnly(ISO8601DateFormatter().string(from: Date()), to: dir.appendingPathComponent(automaticUpgradeMarker))
    }

    static func seedTranscriptForAutomaticUpgrade(in dir: URL, startedAt: Date) {
        let url = dir.appendingPathComponent("transcript.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body = (frontmatter(kind: "Transcript", startedAt: startedAt) + [
            "# Transcript",
            "",
            "_Recording recovered from retained audio._",
            "",
        ]).joined(separator: "\n")
        writeOwnerOnly(body, to: url)
    }

    static func clearAutomaticUpgradePending(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(automaticUpgradeMarker))
    }

    static func pendingAutomaticUpgrades() -> [ArchivedSession] {
        recentSessions(limit: 200).filter {
            $0.isRTIArchive
                && $0.date != nil
                && FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(automaticUpgradeMarker).path)
                && !TranscriptUpgradeAudioDiscovery.inputs(in: $0.url).isEmpty
        }
    }

    /// Persist a session. Silently no-ops if there's nothing to save or the
    /// Application Support directory can't be resolved — archiving is a
    /// best-effort side record, never something that should fail a stop.
    /// Returns the session directory it wrote (nil if nothing was saved) so
    /// the caller can hand it to the vault-side router. `workstreamSlug` is a
    /// pure DECLARATION stamped into frontmatter — all routing policy lives
    /// in the vault's triage tooling, never in this app.
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
        calendarTitle: String? = nil,
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0
    ) -> URL? {
        let hasRetainedAudio = [micRecordingURL, systemRecordingURL]
            .compactMap { $0 }
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        guard !transcript.isEmpty || !chat.isEmpty || !notes.isEmpty || !visualContext.isEmpty || hasRetainedAudio else { return nil }
        guard let dir = sessionDirectory(startedAt: startedAt) else { return nil }

        func fm(_ kind: String) -> [String] {
            frontmatter(kind: kind, startedAt: startedAt, workstreamSlug: workstreamSlug)
        }

        // Only archive a transcript when there's real spoken content (a
        // non-note entry) — a header-only transcript.md just pollutes search.
        if transcript.contains(where: { $0.speakerId != "note" }) || hasRetainedAudio {
            let body = renderTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript, selfName: speakerNames["self"])
            let md = (fm("Transcript") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("transcript.md"))
        }

        // Serialize keyed by display labels ("Remote speaker 1"), not raw ids
        // (`remote_1`): the post-hoc rename UI and any vault-side consumer
        // match names against the labels transcripts actually print.
        let displayKeyedNames = SpeakerLabelMapping.displayKeyedNames(speakerNames)
        if !displayKeyedNames.isEmpty, let data = try? JSONEncoder().encode(displayKeyedNames) {
            let url = dir.appendingPathComponent("speaker-names.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        // Structured threads are the authority when the recording has any:
        // every one of them is projected with its exact thread and turn ids, so
        // a recording that held several chats keeps all of them. The flat dated
        // list is used only when there are no structured threads at all, and it
        // never invents boundaries between them.
        if !chatThreads.isEmpty {
            let body = ChatProjectionMarkdown.render(
                threads: chatThreads,
                startedAt: startedAt,
                endedAt: endedAt,
                unreadableChats: unreadableChatCount,
                header: header(startedAt: startedAt, endedAt: endedAt)
            )
            let md = (fm("Chat") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("chat.md"))
        } else if !chat.isEmpty {
            let body = renderChat(startedAt: startedAt, endedAt: endedAt, entries: chat)
            var lines = [body]
            if unreadableChatCount > 0 {
                lines.append("")
                lines.append("_\(unreadableChatCount) stored chat\(unreadableChatCount == 1 ? "" : "s") in this recording could not be read and \(unreadableChatCount == 1 ? "is" : "are") not shown here. Nothing was removed._")
            }
            let md = (fm("Chat") + lines).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("chat.md"))
        }

        if !notes.isEmpty {
            let body = (["# Notes", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderNotes(notes)]).joined(separator: "\n")
            let md = (fm("Notes") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("notes.md"))
        }
        if !visualContext.isEmpty {
            let body = (["# Screen context", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderVisualContext(visualContext)]).joined(separator: "\n")
            let md = (fm("Screen context") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("screen-context.md"))
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
        let micName = stageRecordingIfPresent(micRecordingURL, as: "audio-mic.wav", in: dir)
        let systemName = stageRecordingIfPresent(systemRecordingURL, as: "audio-system.wav", in: dir)
        writeMetadata(
            ArchiveMetadata(
                sessionId: sessionId,
                systemAudioStartOffsetMs: systemAudioStartOffsetMs,
                micAudioFile: micName,
                systemAudioFile: systemName,
                mode: mode,
                workstream: workstreamName,
                durationSeconds: Int(max(0, endedAt.timeIntervalSince(startedAt))),
                calendarTitle: calendarTitle
            ),
            to: dir
        )
        return dir
    }

    /// Fire the vault-side session router (capture + declare here; route
    /// there). Best-effort and fire-and-forget: missing script or python is a
    /// silent no-op, and the app never waits on or parses the result.
    static func runVaultRouter(sessionDir: URL) {
        guard let script = VaultPaths.vaultToolURL(".claude/tools/triage/route-rti-session.py") else { return }
        ExternalTools.launchDetached(ExternalTools.systemPython, arguments: [script.path, sessionDir.path])
    }

    /// Export RTI's live transcript into the vault's raw-transcript lane
    /// (`meetings/transcripts-raw/`), where the existing `/meeting` pipeline
    /// turns it into the canonical meeting note + Neon-indexed vault document.
    /// This copies out of the RTI archive; it does not move or delete the archive.
    @discardableResult
    static func writeCanonicalMeetingExport(
        startedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?
    ) -> CanonicalMeetingExport? {
        let raw = CanonicalMeetingTranscript.render(entries: transcript)
        return writeCanonicalMeetingExport(
            startedAt: startedAt,
            rawTranscript: raw,
            chat: chat,
            visualContext: visualContext,
            notes: notes,
            archiveDir: archiveDir
        )
    }

    /// Refresh the canonical transcript from the archived `transcript.md`.
    /// Used after the Upgrade Transcript lane replaces the rough live transcript
    /// with an offline provider's better pass.
    @discardableResult
    static func refreshCanonicalMeetingTranscript(fromArchiveDir archiveDir: URL, startedAt: Date) -> URL? {
        let transcriptURL = archiveDir.appendingPathComponent("transcript.md")
        guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
        let raw = CanonicalMeetingTranscript.render(markdownTranscript: markdown)
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

    static func runMeetingProcessor(transcriptURL: URL) {
        guard MeetingProcessorConfig.isEnabled(config: appConfig()) else {
            RTILog.log("meeting processor: auto_process is off; skipped \(transcriptURL.lastPathComponent)", category: .archive)
            return
        }
        guard let claude = ExternalTools.claude() else {
            RTILog.log("meeting processor: claude CLI not found; skipped \(transcriptURL.lastPathComponent)", category: .archive)
            return
        }
        let workdir = vaultRoot(startingAt: transcriptURL.deletingLastPathComponent())
            ?? transcriptURL.deletingLastPathComponent()
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
            proc.terminationHandler = { _ in try? logHandle.close() }
        }
        do {
            try proc.run()
            RTILog.log("meeting processor started for \(transcriptURL.lastPathComponent)", category: .archive)
        } catch {
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
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0
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
            chatThreads: chatThreads,
            unreadableChatCount: unreadableChatCount
        )
        guard !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url = transcriptsRaw.appendingPathComponent("\(stem)-rti.md")
        writeOwnerOnly(sidecar, to: url)
        return url
    }

    @discardableResult
    private static func writeCanonicalMeetingExport(
        startedAt: Date,
        rawTranscript: String,
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        writeSidecar: Bool = true
    ) -> CanonicalMeetingExport? {
        let text = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let transcriptsRaw = meetingTranscriptsRawDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: transcriptsRaw, withIntermediateDirectories: true)

        let stem = canonicalMeetingStem(startedAt: startedAt)
        let transcriptURL = transcriptsRaw.appendingPathComponent("\(stem)-transcript.txt")
        writeOwnerOnly(text + "\n", to: transcriptURL)

        let sidecarURL: URL?
        if writeSidecar {
            let sidecar = renderCanonicalSidecar(
                stem: stem,
                startedAt: startedAt,
                chat: chat,
                visualContext: visualContext,
                notes: notes,
                archiveDir: archiveDir
            )
            if sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidecarURL = nil
            } else {
                let url = transcriptsRaw.appendingPathComponent("\(stem)-rti.md")
                writeOwnerOnly(sidecar, to: url)
                sidecarURL = url
            }
        } else {
            sidecarURL = nil
        }

        RTILog.log("canonical meeting transcript exported: \(transcriptURL.path)", category: .archive)
        return CanonicalMeetingExport(transcriptURL: transcriptURL, sidecarURL: sidecarURL)
    }

    private static func meetingTranscriptsRawDirectory() -> URL? {
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
        chatThreads: [ChatProjectionMarkdown.Thread] = [],
        unreadableChatCount: Int = 0
    ) -> String {
        var lines = [
            "---",
            "source: rti-live",
            "meeting: \(yamlQuoted(stem))",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
            "---",
            "",
            "# RTI live notes — \(stem)",
            "",
            "_Canonical transcript: `\(stem)-transcript.txt`_",
        ]
        if let archiveDir {
            lines.append("_RTI archive: `\(archiveDir.path)`_")
        }
        lines.append("")

        if !notes.isEmpty {
            lines.append("## Generated notes")
            lines.append("")
            lines.append(renderNotes(notes))
            lines.append("")
        }
        if !visualContext.isEmpty {
            lines.append("## Screen context")
            lines.append("")
            lines.append(renderVisualContext(visualContext))
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
        return lines.joined(separator: "\n")
    }

    private static func vaultRoot(startingAt dir: URL) -> URL? {
        VaultPaths.vaultRoot(startingAt: dir)
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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RTI", isDirectory: true)
            .appendingPathComponent("meeting-process-\(stem).log")
    }

    private static let defaultMeetingProcessorPrompt = """
    /meeting {transcript}

    IMPORTANT — this run is UNATTENDED (fired automatically after an RTI session), so be conservative: (1) Always write the meeting note. (2) Set 'projects:' ONLY to an existing project you are confident about. (3) Do NOT create any new vault project folder, do NOT create a Todoist project, and do NOT push Todoist tasks. (4) If the project is new, ambiguous, or you are unsure, set 'projects: [unsorted]' and add a '## Needs routing' section with your best guess and reasoning for the user to confirm. Never guess a project into existence.
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
            return nil
        }
        return folder
    }

    /// Write `string` atomically, then restrict the file to owner-only (0600).
    /// Used for every session-record file (transcript/chat/notes/etc.) so
    /// meeting content isn't world-readable on a multi-user machine.
    private static func writeOwnerOnly(_ string: String, to url: URL) {
        guard (try? string.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Move a kept session-audio artifact into the archive folder so the
    /// transcript, chat, summary, and retained audio live together. If the file
    /// is already in place or missing, quietly no-op.
    private static func stageRecordingIfPresent(_ sourceURL: URL?, as fileName: String, in dir: URL) -> String? {
        guard let sourceURL else { return nil }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let destination = dir.appendingPathComponent(fileName)
        if sourceURL.standardizedFileURL == destination.standardizedFileURL { return fileName }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return fileName
        } catch {
            // Best-effort archive: if move fails (e.g. cross-volume edge case),
            // leave the source in place rather than failing the stop path.
            return nil
        }
    }

    private static func writeMetadata(_ metadata: ArchiveMetadata, to dir: URL) {
        let url = dir.appendingPathComponent("session.json")
        guard let data = try? JSONEncoder().encode(metadata),
              let string = String(data: data, encoding: .utf8) else { return }
        writeOwnerOnly(string, to: url)
    }

    // MARK: - Rendering

    static func renderTranscript(startedAt: Date, endedAt: Date, entries: [LiveEntry], selfName: String? = nil) -> String {
        var lines = ["# Transcript", "", header(startedAt: startedAt, endedAt: endedAt), ""]

        // Originals only — live-translation tokens are a viewing convenience, not
        // part of the kept record.
        let sorted = entries
            .filter { $0.translationStatus != "translation" }
            .sorted { $0.startMs < $1.startMs }

        // Leg-aware labels from the speaker id, never renumbered by who spoke
        // first: `You`, `Room speaker N` (mic), `Remote speaker N` (system).
        // They are the keys of speaker-names.json and the labels the vault's
        // speaker-profiles.py reads the audio leg from, so names stay out of
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
    /// linked-meeting record.
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
    /// linked-meeting record.
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
    private static func renderVisualContext(_ events: [VisualContextEvent]) -> String {
        events.map { event in
            var lines = ["### `\(VisualContextText.timestamp(event.offsetSeconds))`", ""]
            if let frame = event.frameFilename, !frame.isEmpty {
                lines.append("_Frame: frames/\(frame)_")
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
        // Declaration for the vault-side router (route-rti-session.py):
        // which workstream this session was set up against. Facts only —
        // routing policy lives in the vault.
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

    /// Base dir for per-session records. Prefer the vault so captured sessions
    /// live with everything else under `…/projects/personal/rti/sessions`; fall
    /// back to Application Support if the vault can't be located.
    static func sessionsBaseDirectory() -> URL? {
        if let vault = VaultLogStore.rtiDirectory()?.appendingPathComponent("sessions", isDirectory: true) {
            return vault
        }
        return AppSupportPaths.rtiDirectory()?
            .appendingPathComponent("sessions", isDirectory: true)
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
