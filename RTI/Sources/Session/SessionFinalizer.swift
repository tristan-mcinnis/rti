import Foundation
import RTICore

struct GuideArchiveSnapshot {
    let extraction: GuideExtraction
    let guidePath: String
    let rosterPath: String?
    let roster: [GuideSeat]
    /// Exact workbook parser output for a selected Word or Markdown guide.
    var parsedSourceJSON: Data? = nil
}

@MainActor
struct SessionFinalizer {
    struct Snapshot {
        let startedAt: Date
        let endedAt: Date
        let transcript: [LiveEntry]
        let chat: [ChatEntry]
        let visualContext: [VisualContextEvent]
        let notes: [GeneratedNote]
        let sessionId: String?
        let micRecordingURL: URL?
        let systemRecordingURL: URL?
        let systemAudioStartOffsetMs: Int?
        let workstreamItem: VaultItem?
        let modeName: String?
        /// The recording's stored chats, with their exact ids, gathered before
        /// the archive runs. Empty only when the recording had none.
        var chatThreads: [ChatProjectionMarkdown.Thread] = []
        /// Chats in this recording that could not be read. Reported in the
        /// projection, never silently dropped.
        var unreadableChatCount: Int = 0
        var recordingError: String? = nil
        var guide: GuideArchiveSnapshot? = nil
    }

    let snapshot: Snapshot

    func archive() -> URL? {
        if snapshot.recordingError != nil {
            guard let directory = SessionArchive.sessionDirectory(startedAt: snapshot.startedAt),
                  SessionArchive.clearAutomaticUpgradePending(in: directory) else { return nil }
        }
        let markers = SessionMarkers.shared
        let liveSession = snapshot.sessionId != nil && snapshot.sessionId == markers.sessionID
        let evidence = liveSession ? makeEvidence(markers) : nil
        return SessionArchive.write(
            startedAt: snapshot.startedAt,
            endedAt: snapshot.endedAt,
            transcript: snapshot.transcript,
            chat: snapshot.chat,
            visualContext: snapshot.visualContext,
            notes: snapshot.notes,
            sessionId: snapshot.sessionId,
            micRecordingURL: snapshot.micRecordingURL,
            systemRecordingURL: snapshot.systemRecordingURL,
            systemAudioStartOffsetMs: snapshot.systemAudioStartOffsetMs,
            workstreamSlug: Self.workstreamSlug(for: snapshot.workstreamItem),
            mode: snapshot.modeName,
            workstreamName: snapshot.workstreamItem?.name,
            speakerNames: SpeakerNameStore.shared.enteredNames,
            speakerAssignments: SpeakerNameStore.shared.guideAssignments,
            // Stamp the calendar event picked in Prepare into session.json so
            // the Sessions window can title this session (SessionTitleResolver
            // rule 4). Read from the store here, the same way speakerNames is.
            calendarTitle: Self.calendarTitleForArchive(),
            speechContext: MeetingContextStore.shared.sonioxContext(
                callType: snapshot.modeName,
                speakerNames: Array(SpeakerNameStore.shared.names.values).sorted()
            ),
            chatThreads: snapshot.chatThreads,
            unreadableChatCount: snapshot.unreadableChatCount,
            recordingError: snapshot.recordingError,
            guide: snapshot.guide,
            evidence: evidence,
            speakerPolicy: liveSession ? SessionCoordinator.shared.speakerPolicy : nil,
            packageRevision: liveSession ? markers.pinned?.revision : nil
        )
    }

    private func makeEvidence(_ markers: SessionMarkers) -> SessionEvidence {
        let names = SpeakerNameStore.shared
        let guide = GuideSessionController.shared
        let codes = markers.pinned?.items.map(\.code) ?? []
        let turns = GuideTranscript.sources(from: snapshot.transcript).map { source in
            let t = source.turn
            var context = markers.context(at: t.startMs)
            context.guideQuestionID = guide.questionID(atTranscriptMs: t.startMs) ?? context.guideQuestionID
            let named = names.enteredNames[t.speaker] != nil || names.guideAssignments[t.speaker]?.isEmpty == false
            var turn = SessionAnnotatedTurn(turnID: t.id, rawSpeaker: t.speaker, leg: SpeakerEvidence.leg(for: t.speaker),
                                            speakerConfidence: SpeakerEvidence.resolve(speakerID: t.speaker, named: named && source.attributable).rawValue,
                                            original: t.text, liveStartMs: t.startMs, endMs: source.endMs, context: context)
            let discussed = codes.filter { code in
                let escaped = NSRegularExpression.escapedPattern(for: code)
                return t.text.range(of: "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
            }
            if !discussed.isEmpty { turn.discussedCodes = discussed }
            return turn
        }
        return SessionEvidence(sessionID: snapshot.sessionId, groupID: snapshot.guide?.extraction.group,
                               events: markers.timeline.entries,
                               through: Int(max(0, snapshot.endedAt.timeIntervalSince(snapshot.startedAt)) * 1000), turns: turns)
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
}
