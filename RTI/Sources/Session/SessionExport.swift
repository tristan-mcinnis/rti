import Foundation
import GRDB

enum SessionExport {
    static func exportMarkdown(sessionId: String) -> String? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                guard let session = try Session.fetchOne(db, key: sessionId) else { return nil }

                let summary = try SessionSummary.filter(Column("session_id") == sessionId).fetchOne(db)
                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)
                let messages = try ChatMessage
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
                let mode = session.modeId.flatMap { id in
                    try? Mode.fetchOne(db, key: id)
                }

                var lines: [String] = []
                lines.append("---")
                lines.append("title: Session \(session.startedAt.formatted(date: .numeric, time: .shortened))")
                lines.append("date: \(ISO8601DateFormatter().string(from: session.startedAt))")
                if let endedAt = session.endedAt {
                    lines.append("ended: \(ISO8601DateFormatter().string(from: endedAt))")
                }
                if let mode = mode {
                    lines.append("mode: \(mode.name)")
                }
                if let calendarTitle = session.calendarTitle, !calendarTitle.isEmpty {
                    lines.append("calendar_event: \(calendarTitle)")
                }
                lines.append("---")
                lines.append("")

                if let summary = summary {
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
        } catch {
            NSLog("[RTI] SessionExport failed: \(error)")
            return nil
        }
    }

    private static func formatTime(ms: Int) -> String {
        let seconds = ms / 1000
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
