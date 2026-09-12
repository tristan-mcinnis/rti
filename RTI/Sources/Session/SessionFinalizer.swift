import Foundation
import RTICore

@MainActor
struct SessionFinalizer {
    struct Snapshot {
        let startedAt: Date
        let endedAt: Date
        let transcript: [LiveEntry]
        let chat: [ChatEntry]
        let analysis: SessionArchive.Analysis
        let sessionId: String?
        let micRecordingURL: URL?
        let systemRecordingURL: URL?
        let systemAudioStartOffsetMs: Int?
        let workstreamItem: VaultItem?
        let modeName: String?
        let summaryContext: String?
    }

    struct ArchiveResult {
        let archiveDir: URL?
        let transcriptText: String
        let summaryContext: String?
    }

    let snapshot: Snapshot

    func archive() -> ArchiveResult {
        let archiveDir = SessionArchive.write(
            startedAt: snapshot.startedAt,
            endedAt: snapshot.endedAt,
            transcript: snapshot.transcript,
            chat: snapshot.chat,
            analysis: snapshot.analysis,
            sessionId: snapshot.sessionId,
            micRecordingURL: snapshot.micRecordingURL,
            systemRecordingURL: snapshot.systemRecordingURL,
            systemAudioStartOffsetMs: snapshot.systemAudioStartOffsetMs,
            workstreamSlug: Self.workstreamSlug(for: snapshot.workstreamItem),
            mode: snapshot.modeName,
            workstreamName: snapshot.workstreamItem?.name,
            speakerNames: SpeakerNameStore.shared.names,
            // Stamp the calendar event picked in Prepare into session.json so
            // the Sessions window can title this session without waiting on
            // the end-of-session summary (SessionTitleResolver rule 4). Read
            // from the store here, the same way speakerNames is.
            calendarTitle: Self.calendarTitleForArchive()
        )

        return ArchiveResult(
            archiveDir: archiveDir,
            transcriptText: Self.transcriptText(snapshot.transcript),
            summaryContext: snapshot.summaryContext
        )
    }

    /// The title of the calendar event picked in Prepare, trimmed, or nil
    /// when none was picked or it is blank. Stamped into `session.json`.
    static func calendarTitleForArchive() -> String? {
        let title = MeetingContextStore.shared.calendarMeeting?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty ?? true) ? nil : title
    }

    static func workstreamSlug(for item: VaultItem?) -> String? {
        guard item?.isProject == true else { return nil }
        return item?.url.lastPathComponent
    }

    static func transcriptText(_ transcript: [LiveEntry]) -> String {
        TranscriptContext.format(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
