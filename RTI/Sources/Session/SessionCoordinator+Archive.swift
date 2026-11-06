import AppKit
import AVFoundation
import Foundation
import Observation
import RTICore

extension SessionCoordinator {
    /// Write the archive for the in-memory session state (shared by the
    /// normal completeStop path, emergencyShutdown, and the periodic
    /// crash-safety checkpoint). Returns the archive dir. Safe to call
    /// repeatedly — SessionArchive overwrites the same folder. Audio legs and
    /// the canonical export are left to completeStop.
    @discardableResult
    func archiveCurrentSession(endedAt: Date) -> URL? {
        guard let startedAt else { return nil }
        let snapshot = finalizerSnapshot(startedAt: startedAt, endedAt: endedAt, sessionId: currentSessionId, includeAudio: false)
        return SessionFinalizer(snapshot: snapshot).archive()
    }

    func finalizerSnapshot(
        startedAt: Date,
        endedAt: Date,
        sessionId: String?,
        includeAudio: Bool = true
    ) -> SessionFinalizer.Snapshot {
        SessionFinalizer.Snapshot(
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
            modeName: CallTypeStore.shared.active.name,
            chatThreads: chatThreadProjection,
            unreadableChatCount: unreadableChatCount,
            // Only a write or close failure marks the files for review. A mic
            // outage stops the session, but what was captured is intact and
            // still goes through the automatic upgrade.
            recordingError: audioPipeline.recordingFailureMessage
        )
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
                archiveCurrentSession(endedAt: Date())
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
