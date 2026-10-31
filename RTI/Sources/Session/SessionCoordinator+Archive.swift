import AppKit
import AVFoundation
import Foundation
import Observation
import RTICore

extension SessionCoordinator {
    /// Write the archive for the in-memory session state (shared by the
    /// normal completeStop path, emergencyShutdown, and the periodic
    /// crash-safety checkpoint). Returns the archive dir. Safe to call
    /// repeatedly — SessionArchive overwrites the same folder. `route` is
    /// false for mid-session checkpoints: routing a half-finished session
    /// would create a premature field-notes file the final route then skips.
    @discardableResult
    func archiveCurrentSession(endedAt: Date, route: Bool = true) -> URL? {
        guard let startedAt else { return nil }
        let snapshot = finalizerSnapshot(
            startedAt: startedAt,
            endedAt: endedAt,
            sessionId: currentSessionId,
            includeAudio: route
        )
        let dir = SessionFinalizer(snapshot: snapshot).archive()
        if route {
            exportCanonicalMeeting(
                startedAt: startedAt,
                transcript: snapshot.transcript,
                chat: snapshot.chat,
                visualContext: snapshot.visualContext,
                notes: snapshot.notes,
                archiveDir: dir
            )
        }
        return dir
    }

    func finalizerSnapshot(
        startedAt: Date,
        endedAt: Date,
        sessionId: String?,
        includeAudio: Bool = true
    ) -> SessionFinalizer.Snapshot {
        return SessionFinalizer.Snapshot(
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: transcriptPipeline.liveEntries,
            chat: LLMController.shared.entries,
            visualContext: VisualContextTrail.shared.events,
            notes: NotesGenerationController.shared.notes,
            sessionId: sessionId,
            micRecordingURL: includeAudio ? audioPipeline.micRecordingURL : nil,
            systemRecordingURL: includeAudio ? audioPipeline.systemRecordingURL : nil,
            systemAudioStartOffsetMs: systemAudioStartOffsetMs,
            workstreamItem: MeetingContextStore.shared.workstreamItem,
            modeName: ModeStore.shared.activeMode?.name,
            chatThreads: chatThreadProjection,
            unreadableChatCount: unreadableChatCount,
            // Only a write or close failure marks the files for review. A mic
            // outage stops the session, but what was captured is intact and
            // still goes through the automatic upgrade.
            recordingError: audioPipeline.recordingFailureMessage
        )
    }

    private func exportCanonicalMeeting(
        startedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        visualContext: [VisualContextEvent],
        notes: [GeneratedNote],
        archiveDir: URL?,
        process: Bool = true
    ) {
        guard let export = SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt,
            transcript: transcript,
            chat: chat,
            visualContext: visualContext,
            notes: notes,
            archiveDir: archiveDir
        ) else { return }
        if process { SessionArchive.runMeetingProcessor(transcriptURL: export.transcriptURL) }
    }

    /// Crash-safety checkpoint: while a session runs, re-write the archive
    /// every 5 minutes so a hard crash (the one teardown path that can't
    /// archive) loses at most the last few minutes of notes/transcript.
    func startCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard let self, isRunning, !Task.isCancelled else { return }
                archiveCurrentSession(endedAt: Date(), route: false)
            }
        }
    }

    static func archiveWasExpected(for snapshot: SessionFinalizer.Snapshot) -> Bool {
        !snapshot.transcript.isEmpty || !snapshot.chat.isEmpty || !snapshot.notes.isEmpty ||
        !snapshot.visualContext.isEmpty || !snapshot.chatThreads.isEmpty || snapshot.unreadableChatCount > 0 ||
        snapshot.micRecordingURL != nil || snapshot.systemRecordingURL != nil
    }

    func reportArchiveSaveFailure(recordingError: String? = nil) {
        stopErrorRetireTask?.cancel()
        stopErrorRetireTask = nil
        postProcessingStatus = "Save failed · check retained files"
        lastError = recordingError.map { "Recording needs review: \($0) Existing files were kept; check retained audio before processing." }
            ?? "The session could not be fully saved. Existing files were not removed. Check the session folder and retained audio before using Upgrade transcript in Sessions."
        lastErrorIsAuth = false
    }
}
