import Foundation
import RTICore
import UserNotifications

/// Writes a finished session to disk as human-readable Markdown.
///
/// This is the one deliberate exception to the build's "ephemeral by design"
/// rule: when a session ends we keep a record of the real-time transcript
/// (including user-authored notes, which live inline as `speakerId == "note"`
/// entries) and the chat log with the assistant. Audio is still discarded.
///
/// Layout: <vault>/databases/projects/personal/rti/sessions/<yyyy-MM-dd HHmmss>/
/// (falls back to ~/Library/Application Support/RTI/sessions/ if the vault
/// can't be located via Sentinel's config):
///   transcript.md         — the live transcript, notes inline
///   chat.md               — the assistant chat log (only written if non-empty)
///   notes.md              — generated meeting notes (only if any)
///   discussion-guide.md   — discussion-guide coverage (only if a guide loaded)
enum SessionArchive {
    /// The real-time-analysis artifacts produced during a session. Bundled
    /// into one value so the call site in `SessionCoordinator` (and the
    /// linked-meeting hand-off) stay tidy. Everything in here is ephemeral
    /// in-memory state captured at stop time; this archive is the only place
    /// it is written to disk.
    struct Analysis {
        var notes: [GeneratedNote] = []
        var guide: DiscussionGuide?
        var findings: [FindingEntry] = []

        var isEmpty: Bool {
            notes.isEmpty && guide == nil && findings.isEmpty
        }
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
        workstreamSlug: String? = nil,
        linkedMeeting: String? = nil
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
            let body = (["# Findings", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderFindings(analysis.findings)]).joined(separator: "\n")
            let md = (fm("Findings") + [body]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("findings.md"))
        }
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
    static func writeAutoSummary(transcriptText: String, to dir: URL, startedAt: Date) async -> URL? {
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }
        // Full-meeting summaries routinely outlive the default 60s stream
        // timeout (the silent failure that left archives without summary.md)
        // — give this call its own generous budget and log failures.
        // Shape the wrap-up to the session's mode (research debrief for
        // interviews, minutes otherwise) and run it on the reasoning ("smart")
        // model — the end-of-session summary is worth the extra latency.
        let kind = ModeStore.shared.activeMode?.kind ?? .other
        let prompt = PromptCatalogue.summary(for: kind) + "\n\nTranscript:\n" + transcript
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
        // Title by mode: an interview produces a research debrief, not minutes.
        // Also strip any H1 the model prepended (the debrief prompt makes it
        // title the section "# QUALITATIVE RESEARCH DEBRIEF" itself) so the
        // archive doesn't stack two headings.
        let title = kind == .interview ? "# Research debrief" : "# Meeting summary"
        let body = stripLeadingH1(payload)
        let md = (frontmatter(kind: "Summary", startedAt: startedAt) + [title, "", body, ""]).joined(separator: "\n")
        let url = dir.appendingPathComponent("summary.md")
        writeOwnerOnly(md, to: url)
        RTILog.log("auto-summary: wrote summary.md (\(payload.count) chars)", category: "summary")
        notifySummaryReady(sessionFolder: dir.lastPathComponent)
        return url
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
            content.body = "Meeting summary for \(sessionFolder) is in the session archive."
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

    /// Findings ledger: one bullet per tagged finding, in the order logged,
    /// with its `[mm:ss]`, why-it-matters line, and any verbatim quote.
    private static func renderFindings(_ findings: [FindingEntry]) -> String {
        findings.map { f in
            var line = "- **[\(f.tag.label)]** `\(offset(f.rangeMs))` \(f.headline)"
            if !f.matters.isEmpty { line += "\n  - _Matters:_ \(f.matters)" }
            if let quote = f.quote, !quote.isEmpty {
                let who = f.speaker.map { "\($0): " } ?? ""
                line += "\n  - > \(who)\(quote)"
            }
            return line
        }.joined(separator: "\n")
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

        let recordingsDir = URL(fileURLWithPath: meeting.audioFilePath).deletingLastPathComponent()
        let transcriptsRaw = recordingsDir.deletingLastPathComponent()
            .appendingPathComponent("transcripts-raw", isDirectory: true)
        // Only write if Sentinel's transcripts dir already exists — never
        // create stray folders if the path derivation is ever wrong.
        guard FileManager.default.fileExists(atPath: transcriptsRaw.path) else { return }

        let file = transcriptsRaw.appendingPathComponent("\(meeting.name)-rti.md")
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
            lines.append("## Findings")
            lines.append("")
            lines.append(renderFindings(analysis.findings))
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
            lines.append("workstream: \(workstreamSlug)")
        }
        if let linkedMeeting, !linkedMeeting.isEmpty {
            lines.append("linked_meeting: \"\(linkedMeeting)\"")
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

    private static let headerStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Reading the archive (launcher only — reveals in Finder, never reads in-app)

extension SessionArchive {
    struct ArchivedSession: Identifiable, Hashable {
        var id: URL {
            url
        }

        let url: URL
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
            .map { ArchivedSession(url: $0, displayName: prettyName($0.lastPathComponent)) }
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
