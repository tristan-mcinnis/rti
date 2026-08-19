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
        let linkedMeetingName: String?
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
            linkedMeeting: nil,
            mode: snapshot.modeName,
            workstreamName: snapshot.workstreamItem?.name,
            speakerNames: SpeakerNameStore.shared.names
        )

        return ArchiveResult(
            archiveDir: archiveDir,
            transcriptText: Self.transcriptText(snapshot.transcript),
            linkedMeetingName: nil,
            summaryContext: snapshot.summaryContext
        )
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
