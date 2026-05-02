import AppKit
import Foundation
import GRDB
import UniformTypeIdentifiers

enum SessionExport {
    /// Render the session as Markdown and prompt the user with an NSSavePanel.
    /// Pre-fills the filename via `suggestedFilename(for:)`.
    @MainActor
    static func exportToFile(sessionId: String) {
        guard let markdown = exportMarkdown(sessionId: sessionId) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.nameFieldStringValue = suggestedFilename(for: sessionId)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't write export"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

extension SessionExport {
    /// Render an export markdown for a session: combines the canonical
    /// markdown body with the session's chat history (which still lives in
    /// SQLite as the interaction log).
    @MainActor
    static func exportMarkdown(sessionId: String) -> String? {
        guard let session = CorpusBackedStore.session(id: sessionId) else { return nil }
        let entries = CorpusBackedStore.transcripts(forSessionId: sessionId)
        let summary = CorpusBackedStore.summary(forSessionId: sessionId)

        let messages: [ChatMessage] = (try? RTIDatabase.shared.pool.read { db in
            try ChatMessage
                .filter(Column("session_id") == sessionId)
                .order(Column("created_at"))
                .fetchAll(db)
        }) ?? []
        let mode = session.modeId.flatMap { id in
            ModeStore.shared.modes.first(where: { $0.id == id })
        }

        let displayTitle = session.calendarTitle
            ?? session.title
            ?? "Session \(session.startedAt.formatted(date: .numeric, time: .shortened))"

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(displayTitle)")
        lines.append("date: \(ISO8601DateFormatter().string(from: session.startedAt))")
        if let endedAt = session.endedAt {
            lines.append("ended: \(ISO8601DateFormatter().string(from: endedAt))")
        }
        if let mode = mode { lines.append("mode: \(mode.name)") }
        if let calendarTitle = session.calendarTitle, !calendarTitle.isEmpty {
            lines.append("calendar_event: \(calendarTitle)")
        }
        lines.append("---")
        lines.append("")

        if let summary {
            lines.append("# Summary")
            lines.append("")
            lines.append(summary.summaryText)
            lines.append("")
        }
        if let actionItems = summary?.actionItems, !actionItems.isEmpty, actionItems != "None." {
            lines.append("## Action Items")
            lines.append("")
            lines.append(actionItems)
            lines.append("")
        }
        if !entries.isEmpty {
            lines.append("# Transcript")
            lines.append("")
            for e in entries {
                let time = formatTime(ms: e.startMs)
                lines.append("**\(e.speakerId)** (\(time)): \(e.text)")
            }
            lines.append("")
        }
        if !messages.isEmpty {
            lines.append("# Chat")
            lines.append("")
            for m in messages {
                let role = m.role.capitalized
                let action = m.action.map { " [\($0)]" } ?? ""
                lines.append("**\(role)\(action)**: \(m.content)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func suggestedFilename(for sessionId: String) -> String {
        guard let session = CorpusBackedStore.session(id: sessionId) else {
            return "session-export.md"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let datePrefix = formatter.string(from: session.startedAt)
        let rawTitle = session.calendarTitle ?? session.title ?? "meeting"
        let slug = rawTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ";", with: "")
        let safeSlug = String(slug.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .replacingOccurrences(of: "--", with: "-")
            .prefix(60))
        return "\(datePrefix)-\(safeSlug).md"
    }

    private static func formatTime(ms: Int) -> String {
        let seconds = ms / 1000
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
