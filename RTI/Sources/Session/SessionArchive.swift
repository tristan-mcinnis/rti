import Foundation
import RTICore
import UserNotifications

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
/// can't be located via Sentinel's config):
///   transcript.md         — the live transcript, notes inline
///   chat.md               — the assistant chat log (only written if non-empty)
///   notes.md              — generated meeting notes (only if any)
///   discussion-guide.md   — discussion-guide coverage (only if a guide loaded)
///   live-intelligence.md  — decisions/actions/questions/risks (only if any)
///   screen-context.md     — timestamped active-screen OCR changes (only if any)
///   audio-mic.m4a         — retained mic audio for Upgrade Transcript
///   audio-system.m4a      — retained system audio for Upgrade Transcript
enum SessionArchive {
    typealias ArchiveMetadata = SessionArchiveMetadata

    /// The real-time-analysis artifacts produced during a session. Bundled
    /// into one value so the call site in `SessionCoordinator` (and the
    /// linked-meeting hand-off) stay tidy. Everything in here is ephemeral
    /// in-memory state captured at stop time; this archive is the only place
    /// it is written to disk.
    struct Analysis {
        var notes: [GeneratedNote] = []
        var guide: DiscussionGuide?
        var findings: [FindingEntry] = []
        var visualContext: [VisualContextEvent] = []

        var isEmpty: Bool {
            notes.isEmpty && guide == nil && findings.isEmpty && visualContext.isEmpty
        }
    }

    struct CanonicalMeetingExport {
        let transcriptURL: URL
        let sidecarURL: URL?
    }

    /// Persist a session. Silently no-ops if there's nothing to save or the
    /// Application Support directory can't be resolved — archiving is a
    /// best-effort side record, never something that should fail a stop.
    /// Returns the session directory it wrote (nil if nothing was saved) so
    /// the caller can hand it to the vault-side router. `workstreamSlug` and
    /// `linkedMeeting` are pure DECLARATIONS stamped into frontmatter — all
    /// routing policy lives in the vault's triage tooling, never in this app.
    @discardableResult
    static func write(
        startedAt: Date,
        endedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        analysis: Analysis = Analysis(),
        sessionId: String? = nil,
        micRecordingURL: URL? = nil,
        systemRecordingURL: URL? = nil,
        systemAudioStartOffsetMs: Int? = nil,
        workstreamSlug: String? = nil,
        linkedMeeting: String? = nil,
        mode: String? = nil,
        workstreamName: String? = nil
    ) -> URL? {
        guard !transcript.isEmpty || !chat.isEmpty || !analysis.isEmpty else { return nil }
        guard let dir = sessionDirectory(startedAt: startedAt) else { return nil }

        func fm(_ kind: String) -> [String] {
            frontmatter(kind: kind, startedAt: startedAt, workstreamSlug: workstreamSlug, linkedMeeting: linkedMeeting)
        }

        // Only archive a transcript when there's real spoken content (a
        // non-note entry) — a header-only transcript.md just pollutes search.
        if transcript.contains(where: { $0.speakerId != "note" }) {
            let body = renderTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript)
            let md = (fm("Transcript") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("transcript.md"))
        }

        if !chat.isEmpty {
            let body = renderChat(startedAt: startedAt, endedAt: endedAt, entries: chat)
            let md = (fm("Chat") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("chat.md"))
        }

        if !analysis.notes.isEmpty {
            let body = (["# Notes", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderNotes(analysis.notes)]).joined(separator: "\n")
            let md = (fm("Notes") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("notes.md"))
        }
        if let guide = analysis.guide {
            let body = (["# Discussion guide", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderGuide(guide)]).joined(separator: "\n")
            let md = (fm("Discussion guide") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("discussion-guide.md"))
        }
        if !analysis.findings.isEmpty {
            let body = (["# Live intelligence", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderFindings(analysis.findings)]).joined(separator: "\n")
            let md = (fm("Live intelligence") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("live-intelligence.md"))
        }
        if !analysis.visualContext.isEmpty {
            let body = (["# Screen context", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderVisualContext(analysis.visualContext)]).joined(separator: "\n")
            let md = (fm("Screen context") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("screen-context.md"))
        }
        let micName = stageRecordingIfPresent(micRecordingURL, as: "audio-mic.m4a", in: dir)
        let systemName = stageRecordingIfPresent(systemRecordingURL, as: "audio-system.m4a", in: dir)
        writeMetadata(
            ArchiveMetadata(
                sessionId: sessionId,
                systemAudioStartOffsetMs: systemAudioStartOffsetMs,
                micAudioFile: micName,
                systemAudioFile: systemName,
                mode: mode,
                workstream: workstreamName,
                durationSeconds: Int(max(0, endedAt.timeIntervalSince(startedAt))),
                linkedMeeting: linkedMeeting
            ),
            to: dir
        )
        return dir
    }

    /// Generate the Granola-style wrap-up over the full session transcript
    /// and write it as `summary.md` beside the other session files. Quiet
    /// no-op on trivial sessions or LLM failure — the archive must never
    /// depend on a model call succeeding.
    /// - Parameter transcriptText: the rendered transcript, captured by the
    ///   caller at stop time. Passed in (rather than re-read from the live
    ///   session) so starting a new recording before the summary finishes can't
    ///   make it summarise the wrong session.
    /// - Returns: the `summary.md` URL on success, or `nil` if there was nothing
    ///   to summarise or the model call failed (a quiet, non-blocking no-op).
    @MainActor
    @discardableResult
    static func writeAutoSummary(
        transcriptText: String,
        to dir: URL,
        startedAt: Date,
        speakerNames: [String: String] = [:],
        referenceContext: String? = nil
    ) async -> URL? {
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }
        // Full-meeting summaries routinely outlive the default 60s stream
        // timeout (the silent failure that left archives without summary.md)
        // — give this call its own generous budget and log failures.
        // Shape the wrap-up to the session's mode (research debrief for
        // interviews, minutes otherwise) and run it on the reasoning ("smart")
        // model — the end-of-session summary is worth the extra latency.
        let kind = ModeStore.shared.activeMode?.kind ?? .other
        // Piggyback a short session-title on the summary call (one model call,
        // no extra latency). The instruction is appended AFTER the user's
        // editable summary prompt so it never mutates the stored prompt; the
        // model emits a `TITLE:` first line that we parse out and persist as
        // `title.txt` for the Sessions browser to surface as the row label.
        let knownSpeakers = speakerNames
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) is \($0.value.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "; ")
        let speakerContext = knownSpeakers.isEmpty
            ? ""
            : "\n\nKnown speaker identities (use these names, not the anonymous labels): \(knownSpeakers)."
        let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let referenceBlock = reference.isEmpty
            ? ""
            : "\n\nReference context: use it to normalize project vocabulary and likely name misspellings. Treat calendar invitees as invitees, not proof that they attended or spoke. Do not invent facts beyond the transcript and this context.\n\(reference)"
        let prompt = PromptCatalogue.summary(for: kind)
            + "\n\n" + titleInstruction
            + speakerContext
            + referenceBlock
            + "\n\nTranscript:\n" + transcript
        guard let payloadRaw = await LLMRequest().collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)],
            smart: true,
            timeoutOverride: 300
        ) else {
            RTILog.log("auto-summary: LLM call failed/timed out for \(dir.lastPathComponent)", category: "summary")
            return nil
        }
        let payload = payloadRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            RTILog.log("auto-summary: empty response for \(dir.lastPathComponent)", category: "summary")
            return nil
        }
        // Pull the `TITLE:` first line out of the response (best-effort — if
        // the model didn't follow the format, we just get no title and the
        // browser falls back to "Untitled session"). Strip it (and any blank
        // lines after) from the summary body so it doesn't leak into summary.md.
        let (sessionTitle, remainder) = extractTitle(payload)
        let hasManualTitle = FileManager.default.fileExists(atPath: dir.appendingPathComponent("title-manual.txt").path)
        if let sessionTitle, !sessionTitle.isEmpty, !hasManualTitle {
            writeOwnerOnly(sessionTitle, to: dir.appendingPathComponent("title.txt"))
        }
        // Title by mode: an interview produces a research debrief, not minutes.
        // Also strip any H1 the model prepended (the debrief prompt makes it
        // title the section "# QUALITATIVE RESEARCH DEBRIEF" itself) so the
        // archive doesn't stack two headings.
        let title = kind == .interview ? "# Research debrief" : "# Meeting summary"
        let body = stripLeadingH1(remainder)
        let md = (frontmatter(kind: "Summary", startedAt: startedAt) + [title, "", body, ""]).joined(separator: "\n")
        let url = dir.appendingPathComponent("summary.md")
        writeOwnerOnly(md, to: url)
        RTILog.log("auto-summary: wrote summary.md (\(payload.count) chars)" + (sessionTitle.map { ", title: \($0)" } ?? ""), category: "summary")
        notifySummaryReady(sessionFolder: dir.lastPathComponent)
        return url
    }

    /// Instruction appended to the summary prompt asking for a 4–7 word
    /// session title. Leads with the highest-value cue — the format/type
    /// (Briefing, Research, Interview, Review, …) and the subject or brand
    /// when one is discernible — so the Sessions list reads at a glance
    /// ("Acme Sportswear Retail Zone Briefing", not "Meeting at 11:13").
    private static let titleInstruction = """
    SESSION TITLE — on the VERY FIRST LINE of your response, output exactly:
    TITLE: <a 4–7 word title for this session>

    The title names what this session actually IS. Lead with the format/type — \
    Briefing, Research, Interview, Review, Demo, Standup, 1:1, Planning, Debrief, \
    Strategy — then the subject, and the brand or organisation if one is \
    discernible from the transcript (e.g. "Acme Sportswear Retail Zone Briefing", \
    "Q3 Pipeline Review with Timberland", "Athleisure Wear Research Debrief"). \
    No trailing punctuation, no quotes, no prefix other than "TITLE: ". Then a \
    blank line, then the summary.
    """

    /// Pull a leading `TITLE: <text>` line off the model response. Returns the
    /// cleaned title and the remainder (with the TITLE line and the blank
    /// lines immediately after it removed). Case-insensitive on the marker;
    /// tolerates leading whitespace. If the first non-blank line isn't a
    /// TITLE line, returns `(nil, payload)` unchanged so summary.md is
    /// unaffected.
    private static func extractTitle(_ payload: String) -> (String?, String) {
        var lines = payload.components(separatedBy: "\n")
        // Skip leading blanks to find the real first line.
        var lead = 0
        while lead < lines.count, lines[lead].trimmingCharacters(in: .whitespaces).isEmpty {
            lead += 1
        }
        guard lead < lines.count else { return (nil, payload) }
        let candidate = lines[lead].trimmingCharacters(in: .whitespaces)
        guard candidate.lowercased().hasPrefix("title:") else { return (nil, payload) }
        let title = candidate.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
        // Drop the TITLE line + any blank lines right after it.
        lines.removeSubrange(0...lead)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return (title.isEmpty ? nil : title, lines.joined(separator: "\n"))
    }

    /// Drop a single leading H1 (and the blank lines after it) from a model
    /// payload — so a self-titled section ("# QUALITATIVE RESEARCH DEBRIEF")
    /// doesn't double up under the archive's own H1. H2s ("## Overview") are
    /// left untouched: `hasPrefix("# ")` is false for "## ".
    private static func stripLeadingH1(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Local notification when the post-stop summary lands, so the user knows
    /// the wrap-up is readable (Sessions browser / vault) without checking.
    private static func notifySummaryReady(sessionFolder: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Session summary ready"
            content.body = "Tap to read the summary in RTI's Sessions browser."
            // Carried back on tap so the delegate can open this exact session.
            content.userInfo = ["sessionFolder": sessionFolder]
            let request = UNNotificationRequest(identifier: "rti.summary.\(sessionFolder)", content: content, trigger: nil)
            center.add(request)
        }
    }

    /// Fire the vault-side session router (capture + declare here; route
    /// there). Best-effort and fire-and-forget: missing script or python is a
    /// silent no-op, and the app never waits on or parses the result.
    static func runVaultRouter(sessionDir: URL) {
        // databasesDir = <git root>/vault/databases → up two = git root.
        guard let databases = VaultWorkstreamStore.databasesDir() else { return }
        let script = databases
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".claude/tools/triage/route-rti-session.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path, sessionDir.path]
        try? proc.run()
    }

    /// Export RTI's live transcript into the same raw-transcript lane Meeting
    /// Sentinel used, then the existing `/meeting` pipeline can turn it into
    /// the canonical meeting note + Neon-indexed vault document. This copies
    /// out of the RTI archive; it does not move or delete the archive.
    @discardableResult
    static func writeCanonicalMeetingExport(
        startedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        analysis: Analysis,
        archiveDir: URL?,
        linkedMeeting: String?
    ) -> CanonicalMeetingExport? {
        let raw = CanonicalMeetingTranscript.render(entries: transcript)
        return writeCanonicalMeetingExport(
            startedAt: startedAt,
            rawTranscript: raw,
            chat: chat,
            analysis: analysis,
            archiveDir: archiveDir,
            linkedMeeting: linkedMeeting
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
            analysis: Analysis(),
            archiveDir: archiveDir,
            linkedMeeting: nil,
            writeSidecar: false
        )?.transcriptURL
    }

    static func runMeetingProcessor(transcriptURL: URL) {
        guard let claude = claudeExecutableURL() else {
            RTILog.log("meeting processor: claude CLI not found; skipped \(transcriptURL.lastPathComponent)", category: "archive")
            return
        }
        let workdir = vaultRoot(startingAt: transcriptURL.deletingLastPathComponent())
            ?? transcriptURL.deletingLastPathComponent()
        let prompt = meetingProcessorPrompt(transcriptURL: transcriptURL)
        let args = meetingProcessorPermissionArguments()

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
            RTILog.log("meeting processor started for \(transcriptURL.lastPathComponent)", category: "archive")
        } catch {
            try? logHandle?.close()
            RTILog.log("meeting processor failed to start: \(error.localizedDescription)", category: "archive")
        }
    }

    @discardableResult
    private static func writeCanonicalMeetingExport(
        startedAt: Date,
        rawTranscript: String,
        chat: [ChatEntry],
        analysis: Analysis,
        archiveDir: URL?,
        linkedMeeting: String?,
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
                analysis: analysis,
                archiveDir: archiveDir,
                linkedMeeting: linkedMeeting
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

        RTILog.log("canonical meeting transcript exported: \(transcriptURL.path)", category: "archive")
        return CanonicalMeetingExport(transcriptURL: transcriptURL, sidecarURL: sidecarURL)
    }

    private static func meetingTranscriptsRawDirectory() -> URL? {
        if let transcriptsRaw = SentinelPaths.meetingTranscriptsRawDirectory() { return transcriptsRaw }
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
        analysis: Analysis,
        archiveDir: URL?,
        linkedMeeting: String?
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
        if let linkedMeeting, !linkedMeeting.isEmpty {
            lines.append("_Linked meeting: \(linkedMeeting)_")
        }
        lines.append("")

        if let archiveDir,
           let summary = try? String(contentsOf: archiveDir.appendingPathComponent("summary.md"), encoding: .utf8),
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## RTI session summary")
            lines.append("")
            lines.append(bodyAfterFrontmatter(summary).trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        if !analysis.notes.isEmpty {
            lines.append("## Generated notes")
            lines.append("")
            lines.append(renderNotes(analysis.notes))
            lines.append("")
        }
        if let guide = analysis.guide {
            lines.append("## Discussion guide")
            lines.append("")
            lines.append(renderGuide(guide))
            lines.append("")
        }
        if !analysis.findings.isEmpty {
            lines.append("## Live intelligence")
            lines.append("")
            lines.append(renderFindings(analysis.findings))
            lines.append("")
        }
        if !analysis.visualContext.isEmpty {
            lines.append("## Screen context")
            lines.append("")
            lines.append(renderVisualContext(analysis.visualContext))
            lines.append("")
        }
        if !chat.isEmpty {
            lines.append("## Assistant chat")
            lines.append("")
            lines += chatBlock(chat)
        }
        return lines.joined(separator: "\n")
    }

    private static func bodyAfterFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return text
        }
        return String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
    }

    private static func claudeExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func vaultRoot(startingAt dir: URL) -> URL? {
        SentinelPaths.vaultRoot(startingAt: dir)
    }

    private static func meetingProcessorPrompt(transcriptURL: URL) -> String {
        let template = sentinelConfig()["auto_process_prompt"] as? String
            ?? defaultMeetingProcessorPrompt
        return template.replacingOccurrences(of: "{transcript}", with: transcriptURL.path)
    }

    private static func meetingProcessorPermissionArguments() -> [String] {
        let yolo = (sentinelConfig()["auto_process_yolo"] as? Bool) ?? true
        return yolo
            ? ["--dangerously-skip-permissions"]
            : ["--permission-mode", "acceptEdits"]
    }

    private static func sentinelConfig() -> [String: Any] {
        SentinelPaths.configDictionary()
    }

    private static func sentinelConfigURL() -> URL {
        SentinelPaths.configURL()
    }

    private static func meetingProcessorLogURL(stem: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RTI", isDirectory: true)
            .appendingPathComponent("meeting-process-\(stem).log")
    }

    private static let defaultMeetingProcessorPrompt = """
    /meeting {transcript}

    IMPORTANT — this run is UNATTENDED (fired automatically after an RTI session), so be conservative: (1) Always write the meeting note. (2) Set 'projects:' ONLY to an existing project you are confident about. (3) Do NOT create any new vault project folder, do NOT create a Todoist project, and do NOT push Todoist tasks. (4) If the project is new, ambiguous, or you are unsure, set 'projects: [unsorted]' and add a '## Needs routing' section with your best guess and reasoning for Tristan to confirm. Never guess a project into existence.
    """

    private static func sessionDirectory(startedAt: Date) -> URL? {
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

    private static func renderTranscript(startedAt: Date, endedAt: Date, entries: [LiveEntry]) -> String {
        var lines = ["# Transcript", "", header(startedAt: startedAt, endedAt: endedAt), ""]

        // Originals only — live-translation tokens are a viewing convenience, not
        // part of the kept record.
        let sorted = entries
            .filter { $0.translationStatus != "translation" }
            .sorted { $0.startMs < $1.startMs }

        // Neutral, appearance-ordered speaker labels — matching the live view.
        // The capture channel (mic vs system) doesn't identify who's talking.
        var speakerNumber: [String: Int] = [:]
        var nextNumber = 1
        func label(for id: String) -> String {
            if id == "note" { return "📝 Note" }
            if let n = speakerNumber[id] { return "Speaker \(n)" }
            let n = nextNumber
            speakerNumber[id] = n
            nextNumber += 1
            return "Speaker \(n)"
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

    /// Combined markdown for generated notes — one block per note, newest
    /// material last, separated by rules. Shared by the local archive and the
    /// linked-meeting record.
    private static func renderNotes(_ notes: [GeneratedNote]) -> String {
        notes.map { n in
            var head = "### \(offset(n.rangeStartMs)) – \(offset(n.rangeEndMs))"
            if !n.title.isEmpty { head += " · \(n.title)" }
            return "\(head)\n\n\(n.content)"
        }.joined(separator: "\n\n")
    }

    /// Live intelligence ledger: one bullet per tagged work object, in the
    /// order logged, with its `[mm:ss]`, why line, and any source quote.
    private static func renderFindings(_ findings: [FindingEntry]) -> String {
        findings.map { f in
            var line = "- **[\(f.tag.label)]** `\(offset(f.rangeMs))` \(f.headline)"
            if !f.matters.isEmpty { line += "\n  - _Why:_ \(f.matters)" }
            if let quote = f.quote, !quote.isEmpty {
                let who = f.speaker.map { "\($0): " } ?? ""
                line += "\n  - > \(who)\(quote)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Materially changed active-screen OCR frames. Images never enter the
    /// archive; this compact evidence trail is what the vault and agent keep.
    private static func renderVisualContext(_ events: [VisualContextEvent]) -> String {
        events.map { event in
            "### `\(VisualContextText.timestamp(event.offsetSeconds))`\n\n\(event.text)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// Discussion-guide coverage: a header line plus each question with its
    /// status and any matched quotes.
    private static func renderGuide(_ guide: DiscussionGuide) -> String {
        let cov = guide.coverage
        var lines = ["**\(guide.fileName)** — \(cov.answered)/\(cov.total) answered (\(cov.percent)%)", ""]
        for obj in guide.objectives {
            lines.append("## \(obj.title)")
            if let desc = obj.description, !desc.isEmpty { lines.append(desc) }
            lines.append("")
            for sec in obj.sections {
                lines.append("### \(sec.title)")
                lines.append("")
                for q in sec.questions {
                    let mark = q.status == .answered ? "x" : " "
                    lines.append("- [\(mark)] \(q.text)")
                    if let r = q.response {
                        lines.append("  - \(r.summary)")
                        for quote in r.quotes {
                            let stamp = quote.formattedTimestamp.isEmpty ? "" : "`\(quote.formattedTimestamp)` "
                            lines.append("  - > \(stamp)\(quote.text)")
                        }
                    }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Linked Meeting Sentinel record

    /// When the RTI session was linked to a meeting that Meeting Sentinel is
    /// recording, drop RTI's notes + chat next to Sentinel's raw transcript so
    /// the downstream vault/Hermes workflow can fold them in. Keyed by the
    /// meeting stem; the destination is derived from Sentinel's own audio path
    /// (`<meetings>/recordings/<stem>.m4a` → `<meetings>/transcripts-raw/`)
    /// rather than a hardcoded vault location. RTI's rough live transcript is
    /// deliberately omitted — Sentinel's batch transcript is the record-of-truth.
    static func writeLinkedMeetingNotes(
        meeting: SentinelMeeting,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        analysis: Analysis = Analysis()
    ) {
        let notes = transcript.filter { $0.speakerId == "note" }
        guard !notes.isEmpty || !chat.isEmpty || !analysis.isEmpty else { return }

        let file = SentinelPaths.linkedMeetingNotesURL(audioFilePath: meeting.audioFilePath, meetingName: meeting.name)
        let transcriptsRaw = file.deletingLastPathComponent()
        // Only write if Sentinel's transcripts dir already exists — never
        // create stray folders if the path derivation is ever wrong.
        guard FileManager.default.fileExists(atPath: transcriptsRaw.path) else { return }

        let md = renderLinkedMeeting(meeting: meeting, userNotes: notes, chat: chat, analysis: analysis)
        writeOwnerOnly(md, to: file)
    }

    private static func renderLinkedMeeting(
        meeting: SentinelMeeting,
        userNotes: [LiveEntry],
        chat: [ChatEntry],
        analysis: Analysis
    ) -> String {
        var lines = [
            "---",
            "source: rti-live",
            "meeting: \(meeting.name)",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
            "---",
            "",
            "# RTI live notes — \(meeting.name)",
            "",
        ]
        if !userNotes.isEmpty {
            lines.append("## User notes")
            lines.append("")
            for note in userNotes.sorted(by: { $0.startMs < $1.startMs }) {
                lines.append("- `\(offset(note.startMs))` \(note.text)")
            }
            lines.append("")
        }
        if !analysis.notes.isEmpty {
            lines.append("## Generated notes")
            lines.append("")
            lines.append(renderNotes(analysis.notes))
            lines.append("")
        }
        if let guide = analysis.guide {
            lines.append("## Discussion guide")
            lines.append("")
            lines.append(renderGuide(guide))
            lines.append("")
        }
        if !analysis.findings.isEmpty {
            lines.append("## Live intelligence")
            lines.append("")
            lines.append(renderFindings(analysis.findings))
            lines.append("")
        }
        if !analysis.visualContext.isEmpty {
            lines.append("## Screen context")
            lines.append("")
            lines.append(renderVisualContext(analysis.visualContext))
            lines.append("")
        }
        if !chat.isEmpty {
            lines.append("## Assistant chat")
            lines.append("")
            lines += chatBlock(chat)
        }
        return lines.joined(separator: "\n")
    }

    private static func header(startedAt: Date, endedAt: Date) -> String {
        let started = headerStamp.string(from: startedAt)
        let seconds = Int(max(0, endedAt.timeIntervalSince(startedAt)))
        return "_\(started) · \(duration(seconds))_"
    }

    /// YAML frontmatter so the vault's Neon ingester titles + links these files
    /// (mirrors `renderLinkedMeeting`'s block). Must be the very first thing in
    /// the file, before the H1. `kind` is the file's human label, e.g.
    /// "Transcript" / "Chat" / "Notes" / "Discussion guide". `type: reference`
    /// keeps all four out of the meeting_note / transcript / discussion_guide
    /// buckets the ingester would otherwise infer from the filename.
    private static func frontmatter(
        kind: String,
        startedAt: Date,
        workstreamSlug: String? = nil,
        linkedMeeting: String? = nil
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
        // Declarations for the vault-side router (route-rti-session.py):
        // which workstream this session was set up against, and which Sentinel
        // meeting it overlaid. Facts only — routing policy lives in the vault.
        if let workstreamSlug, !workstreamSlug.isEmpty {
            lines.append("workstream: \(yamlQuoted(workstreamSlug))")
        }
        if let linkedMeeting, !linkedMeeting.isEmpty {
            lines.append("linked_meeting: \(yamlQuoted(linkedMeeting))")
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
        /// Parsed from the `yyyy-MM-dd HHmmss` folder name. Nil if the folder
        /// isn't a recognised stamp (falls back to a flat list under "Earlier").
        let date: Date?
        /// Short AI-generated title (from `title.txt`, written alongside the
        /// auto-summary). Nil until the summary lands, or if it failed — the
        /// browser then shows "Untitled session".
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
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RTI", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Recent archived sessions, newest first (folder names are timestamp-
    /// prefixed, so reverse lexicographic = newest-first). Backs a convenience
    /// launcher only — returns folders to reveal in Finder, not content to read.
    static func recentSessions(limit: Int = 10) -> [ArchivedSession] {
        guard let base = sessionsBaseDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              )
        else { return [] }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { ArchivedSession(
                url: $0,
                date: folderStamp.date(from: $0.lastPathComponent),
                title: titleFile(at: $0),
                displayName: prettyName($0.lastPathComponent)
            ) }
    }

    /// Read the one-line title written by `writeAutoSummary` (best-effort:
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
