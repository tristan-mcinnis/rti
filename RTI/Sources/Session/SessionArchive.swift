import Foundation
import RTICore

/// Writes a finished session to disk as human-readable Markdown.
///
/// This is the one deliberate exception to the build's "ephemeral by design"
/// rule: when a session ends we keep a record of the real-time transcript
/// (including user-authored notes, which live inline as `speakerId == "note"`
/// entries) and the chat log with the assistant. Audio is still discarded.
///
/// Layout: ~/Library/Application Support/RTI/sessions/<yyyy-MM-dd HHmmss>/
///   transcript.md         — the live transcript, notes inline
///   chat.md               — the assistant chat log (only written if non-empty)
///   notes.md              — generated meeting notes (only if any)
///   dossiers.md           — extracted entity dossiers (only if any)
///   discussion-guide.md   — discussion-guide coverage (only if a guide loaded)
enum SessionArchive {
    /// The real-time-analysis artifacts produced during a session. Bundled
    /// into one value so the call site in `SessionCoordinator` (and the
    /// linked-meeting hand-off) stay tidy. Everything in here is ephemeral
    /// in-memory state captured at stop time; this archive is the only place
    /// it is written to disk.
    struct Analysis {
        var notes: [GeneratedNote] = []
        var dossiers: [EntityDossier] = []
        var guide: DiscussionGuide?

        var isEmpty: Bool { notes.isEmpty && dossiers.isEmpty && guide == nil }
    }

    /// Persist a session. Silently no-ops if there's nothing to save or the
    /// Application Support directory can't be resolved — archiving is a
    /// best-effort side record, never something that should fail a stop.
    static func write(
        startedAt: Date,
        endedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        analysis: Analysis = Analysis()
    ) {
        guard !transcript.isEmpty || !chat.isEmpty || !analysis.isEmpty else { return }
        guard let dir = sessionDirectory(startedAt: startedAt) else { return }

        let transcriptMD = renderTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript)
        writeOwnerOnly(transcriptMD, to: dir.appendingPathComponent("transcript.md"))

        if !chat.isEmpty {
            let chatMD = renderChat(startedAt: startedAt, endedAt: endedAt, entries: chat)
            writeOwnerOnly(chatMD, to: dir.appendingPathComponent("chat.md"))
        }

        if !analysis.notes.isEmpty {
            let md = (["# Notes", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderNotes(analysis.notes)]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("notes.md"))
        }
        if !analysis.dossiers.isEmpty {
            let md = (["# Dossiers", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderDossiers(analysis.dossiers)]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("dossiers.md"))
        }
        if let guide = analysis.guide {
            let md = (["# Discussion guide", "", header(startedAt: startedAt, endedAt: endedAt), ""] + [renderGuide(guide)]).joined(separator: "\n")
            writeOwnerOnly(md, to: dir.appendingPathComponent("discussion-guide.md"))
        }
    }

    private static func sessionDirectory(startedAt: Date) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base
            .appendingPathComponent("RTI", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(folderStamp.string(from: startedAt), isDirectory: true)
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
        for entry in entries.sorted(by: { $0.startMs < $1.startMs }) {
            let clock = offset(entry.startMs)
            if entry.speakerId == "note" {
                lines.append("`\(clock)` **📝 Note:** \(entry.text)")
            } else {
                lines.append("`\(clock)` **\(speakerLabel(entry.speakerId)):** \(entry.text)")
            }
            lines.append("")
        }
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
            let when = headerStamp.string(from: n.timestamp)
            return "### \(when)\n\n\(n.content)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// Dossiers grouped by entity type, each a bolded name + description.
    private static func renderDossiers(_ dossiers: [EntityDossier]) -> String {
        let grouped = Dictionary(grouping: dossiers) { $0.type }
        let groups = grouped.keys.sorted { $0.displayName < $1.displayName }
        return groups.map { type in
            let entries = (grouped[type] ?? []).map { "- **\($0.name)** — \($0.description)" }
            return "## \(type.displayName)\n\n\(entries.joined(separator: "\n"))"
        }.joined(separator: "\n\n")
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
        if !analysis.dossiers.isEmpty {
            lines.append("## Dossiers")
            lines.append("")
            lines.append(renderDossiers(analysis.dossiers))
            lines.append("")
        }
        if let guide = analysis.guide {
            lines.append("## Discussion guide")
            lines.append("")
            lines.append(renderGuide(guide))
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

    // MARK: - Formatting helpers

    /// "them_1" → "Them 1", "self" → "You", anything else title-cased.
    private static func speakerLabel(_ id: String) -> String {
        switch id {
        case "self": return "You"
        default:
            if id.hasPrefix("them_"), let n = id.split(separator: "_").last {
                return "Them \(n)"
            }
            return id.capitalized
        }
    }

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
