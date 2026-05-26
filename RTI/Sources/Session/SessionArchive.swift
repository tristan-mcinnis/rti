import Foundation

/// Writes a finished session to disk as human-readable Markdown.
///
/// This is the one deliberate exception to the build's "ephemeral by design"
/// rule: when a session ends we keep a record of the real-time transcript
/// (including user-authored notes, which live inline as `speakerId == "note"`
/// entries) and the chat log with the assistant. Audio is still discarded.
///
/// Layout: ~/Library/Application Support/RTI/sessions/<yyyy-MM-dd HHmmss>/
///   transcript.md   — the live transcript, notes inline
///   chat.md         — the assistant chat log (only written if non-empty)
enum SessionArchive {
    /// Persist a session. Silently no-ops if there's nothing to save or the
    /// Application Support directory can't be resolved — archiving is a
    /// best-effort side record, never something that should fail a stop.
    static func write(startedAt: Date, endedAt: Date, transcript: [LiveEntry], chat: [ChatEntry]) {
        guard !transcript.isEmpty || !chat.isEmpty else { return }
        guard let dir = sessionDirectory(startedAt: startedAt) else { return }

        let transcriptMD = renderTranscript(startedAt: startedAt, endedAt: endedAt, entries: transcript)
        try? transcriptMD.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        if !chat.isEmpty {
            let chatMD = renderChat(startedAt: startedAt, endedAt: endedAt, entries: chat)
            try? chatMD.write(to: dir.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)
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
        } catch {
            return nil
        }
        return folder
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
            if let project = entry.appliedProjectName { tags.append("project: \(project)") }
            let suffix = tags.isEmpty ? "" : " _(\(tags.joined(separator: ", ")))_"
            lines.append("**\(speaker)**\(suffix)")
            lines.append("")
            lines.append(entry.text)
            lines.append("")
        }
        return lines
    }

    // MARK: - Linked Meeting Sentinel record

    /// When the RTI session was linked to a meeting that Meeting Sentinel is
    /// recording, drop RTI's notes + chat next to Sentinel's raw transcript so
    /// the downstream vault/Hermes workflow can fold them in. Keyed by the
    /// meeting stem; the destination is derived from Sentinel's own audio path
    /// (`<meetings>/recordings/<stem>.m4a` → `<meetings>/transcripts-raw/`)
    /// rather than a hardcoded vault location. RTI's rough live transcript is
    /// deliberately omitted — Sentinel's batch transcript is the record-of-truth.
    static func writeLinkedMeetingNotes(meeting: SentinelMeeting, transcript: [LiveEntry], chat: [ChatEntry]) {
        let notes = transcript.filter { $0.speakerId == "note" }
        guard !notes.isEmpty || !chat.isEmpty else { return }

        let recordingsDir = URL(fileURLWithPath: meeting.audioFilePath).deletingLastPathComponent()
        let transcriptsRaw = recordingsDir.deletingLastPathComponent()
            .appendingPathComponent("transcripts-raw", isDirectory: true)
        // Only write if Sentinel's transcripts dir already exists — never
        // create stray folders if the path derivation is ever wrong.
        guard FileManager.default.fileExists(atPath: transcriptsRaw.path) else { return }

        let file = transcriptsRaw.appendingPathComponent("\(meeting.name)-rti.md")
        let md = renderLinkedMeeting(meeting: meeting, notes: notes, chat: chat)
        try? md.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func renderLinkedMeeting(meeting: SentinelMeeting, notes: [LiveEntry], chat: [ChatEntry]) -> String {
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
        if !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            for note in notes.sorted(by: { $0.startMs < $1.startMs }) {
                lines.append("- `\(offset(note.startMs))` \(note.text)")
            }
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
