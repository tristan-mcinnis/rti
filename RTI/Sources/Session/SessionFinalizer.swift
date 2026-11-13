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

/// Serializes archive writes. A checkpoint renders and writes on a utility
/// task while the call goes on; the write at stop or quit runs on main and
/// waits here for a checkpoint still writing, so the newest snapshot always
/// lands last. A job older than the last one written is skipped.
/// `@unchecked Sendable`: `writing` is held for a whole write, and `state`
/// guards the counters.
final class ArchiveWriteGate: @unchecked Sendable {
    static let shared = ArchiveWriteGate()
    private let writing = NSLock()
    private let state = NSLock()
    private var issued = 0
    private var written = 0

    func nextSequence() -> Int {
        state.withLock {
            issued += 1
            return issued
        }
    }

    func run(_ sequence: Int, _ write: () -> URL?) -> URL? {
        writing.withLock {
            guard state.withLock({ sequence > written }) else { return nil }
            let result = write()
            state.withLock { written = max(written, sequence) }
            return result
        }
    }
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

    /// Everything one archive write needs, read from the live stores on
    /// main. A value, so a checkpoint can render and write it on a utility
    /// task (`SessionCoordinator.startCheckpointLoop`).
    struct Job: Sendable {
        let snapshot: Snapshot
        let sequence: Int
        let speakerNames: [String: String]
        let speakerAssignments: [String: GuideSpeakerAssignment]
        let calendarTitle: String?
        let speechContext: SonioxContext?
        let evidence: EvidenceInput?
        let speakerPolicy: SessionSpeakerPolicy?
        let packageRevision: String?
    }

    /// The live inputs of `SessionEvidence`, so its turns are built off main.
    struct EvidenceInput: Sendable {
        let events: [SessionNote]
        let timeline: MarkerTimeline
        let codes: [String]
        /// Raw speaker ids the user named or seated.
        let namedSpeakers: Set<String>
        let questions: GuideSessionController.QuestionLookup
    }

    /// Write the archive now, on the caller's thread. Used at stop, on quit
    /// and by tests.
    func archive() -> URL? {
        Self.write(prepare())
    }

    /// Read the live stores. Cheap: the arrays are copy-on-write.
    func prepare() -> Job {
        let markers = SessionMarkers.shared
        let liveSession = snapshot.sessionId != nil && snapshot.sessionId == markers.sessionID
        let names = SpeakerNameStore.shared
        let evidence = liveSession ? EvidenceInput(
            events: markers.timeline.entries,
            timeline: markers.timeline,
            codes: markers.pinned?.items.map(\.code) ?? [],
            namedSpeakers: Set(names.enteredNames.keys).union(names.guideAssignments.filter { !$0.value.isEmpty }.keys),
            questions: GuideSessionController.shared.questionLookup
        ) : nil
        return Job(
            snapshot: snapshot,
            sequence: ArchiveWriteGate.shared.nextSequence(),
            speakerNames: names.enteredNames,
            speakerAssignments: names.guideAssignments,
            // Stamp the calendar event picked in Prepare into session.json so
            // the Sessions window can title this session (SessionTitleResolver
            // rule 4). Read from the store here, the same way speakerNames is.
            calendarTitle: Self.calendarTitleForArchive(),
            speechContext: MeetingContextStore.shared.sonioxContext(
                callType: snapshot.modeName,
                speakerNames: Array(names.names.values).sorted()
            ),
            evidence: evidence,
            speakerPolicy: liveSession ? SessionCoordinator.shared.speakerPolicy : nil,
            packageRevision: liveSession ? markers.pinned?.revision : nil
        )
    }

    /// Render and write one job. Writes are serialized, and a job older
    /// than one already written is skipped (`ArchiveWriteGate`).
    nonisolated static func write(_ job: Job) -> URL? {
        ArchiveWriteGate.shared.run(job.sequence) {
            let snapshot = job.snapshot
            if snapshot.recordingError != nil {
                guard let directory = SessionArchive.sessionDirectory(startedAt: snapshot.startedAt),
                      SessionArchive.clearAutomaticUpgradePending(in: directory) else { return nil }
            }
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
                workstreamSlug: workstreamSlug(for: snapshot.workstreamItem),
                mode: snapshot.modeName,
                workstreamName: snapshot.workstreamItem?.name,
                speakerNames: job.speakerNames,
                speakerAssignments: job.speakerAssignments,
                calendarTitle: job.calendarTitle,
                speechContext: job.speechContext,
                chatThreads: snapshot.chatThreads,
                unreadableChatCount: snapshot.unreadableChatCount,
                recordingError: snapshot.recordingError,
                guide: snapshot.guide,
                evidence: job.evidence.map { makeEvidence($0, snapshot: snapshot) },
                speakerPolicy: job.speakerPolicy,
                packageRevision: job.packageRevision
            )
        }
    }

    nonisolated static func makeEvidence(_ input: EvidenceInput, snapshot: Snapshot) -> SessionEvidence {
        let matchers = codeMatchers(for: input.codes)
        let turns = GuideTranscript.sources(from: snapshot.transcript).map { source in
            let t = source.turn
            var context = input.timeline.context(at: t.startMs)
            context.guideQuestionID = input.questions.questionID(at: t.startMs) ?? context.guideQuestionID
            let named = input.namedSpeakers.contains(t.speaker)
            var turn = SessionAnnotatedTurn(turnID: t.id, rawSpeaker: t.speaker, leg: SpeakerEvidence.leg(for: t.speaker),
                                            speakerConfidence: SpeakerEvidence.resolve(speakerID: t.speaker, named: named && source.attributable).rawValue,
                                            original: t.text, liveStartMs: t.startMs, endMs: source.endMs, context: context)
            let discussed = discussedCodes(in: t.text, matchers: matchers)
            if !discussed.isEmpty { turn.discussedCodes = discussed }
            return turn
        }
        return SessionEvidence(sessionID: snapshot.sessionId, groupID: snapshot.guide?.extraction.group,
                               events: input.events,
                               through: Int(max(0, snapshot.endedAt.timeIntervalSince(snapshot.startedAt)) * 1000), turns: turns)
    }

    /// One whole-token, case-insensitive pattern per pinned code, compiled
    /// once per archive rather than once per code per turn. Separate
    /// patterns, not one alternation: package codes are free text, and an
    /// alternation takes only the longest of two overlapping codes ("Board 1"
    /// and "1"), while each code here is found on its own.
    nonisolated static func codeMatchers(for codes: [String]) -> [(code: String, pattern: NSRegularExpression)] {
        codes.compactMap { code in
            let escaped = NSRegularExpression.escapedPattern(for: code)
            return (try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])",
                                             options: .caseInsensitive)).map { (code, $0) }
        }
    }

    /// The pinned codes a turn names, in package order.
    nonisolated static func discussedCodes(in text: String,
                                           matchers: [(code: String, pattern: NSRegularExpression)]) -> [String] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return matchers.filter { $0.pattern.firstMatch(in: text, range: range) != nil }.map(\.code)
    }

    /// The title of the calendar event picked in Prepare, trimmed, or nil
    /// when none was picked or it is blank. Stamped into `session.json`.
    static func calendarTitleForArchive() -> String? {
        let title = MeetingContextStore.shared.calendarMeeting?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty ?? true) ? nil : title
    }

    nonisolated static func workstreamSlug(for item: VaultItem?) -> String? {
        guard item?.isProject == true else { return nil }
        return item?.url.lastPathComponent
    }
}
