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
    /// the canonical export are left to completeStop; the quit path adds
    /// its sidecar through `writeQuitRecord`.
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
            // Only 30 s of failed writes or a close failure marks the files
            // for review. A mic outage or a brief write failure never stops
            // the session and goes through the automatic upgrade.
            recordingError: audioPipeline.recordingFailureMessage,
            guide: sessionId.flatMap { GuideSessionController.shared.snapshot(for: $0) },
            // A leg that recorded nothing for a stretch is written down, so
            // /meeting never reads a one-sided stretch as a quiet one.
            captureGaps: audioPipeline.captureGaps
        )
    }

    /// Crash-safety checkpoint: while a session runs, re-write the archive
    /// every 5 minutes so a hard crash (the one teardown path that can't
    /// archive) loses at most the last few minutes of notes/transcript.
    /// Only the snapshot is taken on main; the rendering and the file writes
    /// run on a utility task (2026-11-13 M1 audit: 50 to 150 ms on main per
    /// checkpoint at two hours). `ArchiveWriteGate` keeps the stop's own
    /// write after any checkpoint still writing.
    func startCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard let self, isRunning, !Task.isCancelled else { return }
                await checkpoint(endedAt: Date())
            }
        }
    }

    /// One crash-safety checkpoint: snapshot on main, write off main.
    func checkpoint(endedAt: Date) async {
        guard let job = PassSignpost.interval("checkpoint snapshot", { checkpointJob(endedAt: endedAt) }) else { return }
        await Task.detached(priority: .utility) {
            _ = SessionFinalizer.write(job)
        }.value
    }

    func checkpointJob(endedAt: Date) -> SessionFinalizer.Job? {
        guard let startedAt else { return nil }
        let snapshot = finalizerSnapshot(startedAt: startedAt, endedAt: endedAt, sessionId: currentSessionId, includeAudio: false)
        return SessionFinalizer(snapshot: snapshot).prepare()
    }

    /// The `-rti.md` sidecar for a stopped session: generated notes, typed
    /// notes, screen context and chat threads. Written on the normal path
    /// and on the review path, so a recording that stopped early or failed
    /// to close still hands its notes and chat to `/meeting`.
    @discardableResult
    static func writeStopSidecar(snapshot: SessionFinalizer.Snapshot, archiveDir: URL?, callType: CallType) -> URL? {
        SessionArchive.writeCanonicalMeetingSidecar(
            startedAt: snapshot.startedAt,
            chat: snapshot.chat,
            visualContext: snapshot.visualContext,
            notes: snapshot.notes,
            archiveDir: archiveDir,
            callType: callType,
            chatThreads: snapshot.chatThreads,
            unreadableChatCount: snapshot.unreadableChatCount,
            typedNotes: snapshot.transcript.filter { $0.speakerId == "note" }
        )
    }

    /// Quit before completeStop: the archive, then the `/meeting` sidecar.
    /// completeStop is the only other writer of that sidecar; without this
    /// the next launch's upgrade wrote one with no generated notes, chat or
    /// screen context.
    @discardableResult
    static func writeQuitRecord(snapshot: SessionFinalizer.Snapshot, callType: CallType) -> (archive: URL?, sidecar: URL?) {
        guard let archiveDir = SessionFinalizer(snapshot: snapshot).archive() else { return (nil, nil) }
        return (archiveDir, writeStopSidecar(snapshot: snapshot, archiveDir: archiveDir, callType: callType))
    }

    static func archiveWasExpected(for snapshot: SessionFinalizer.Snapshot) -> Bool {
        !snapshot.transcript.isEmpty || !snapshot.chat.isEmpty || !snapshot.notes.isEmpty ||
            !snapshot.visualContext.isEmpty || !snapshot.chatThreads.isEmpty || snapshot.unreadableChatCount > 0 ||
            snapshot.micRecordingURL != nil || snapshot.systemRecordingURL != nil || snapshot.guide != nil
    }

    func reportArchiveSaveFailure(recordingError: String? = nil, sidecarMissing: Bool = false) {
        stopErrorRetireTask?.cancel()
        stopErrorRetireTask = nil
        postProcessingStatus = "Save failed · check retained files"
        lastError = Self.archiveSaveFailureMessage(recordingError: recordingError, sidecarMissing: sidecarMissing)
        lastErrorIsAuth = false
    }

    /// No upgrade runs on a recording marked for review, so nothing else
    /// would write the `/meeting` notes file; the message says so.
    static func archiveSaveFailureMessage(recordingError: String?, sidecarMissing: Bool) -> String {
        let base = recordingError.map { "Recording needs review: \($0) Existing files were kept; check retained audio before processing." }
            ?? "The session could not be fully saved. Existing files were not removed. Check the session folder and retained audio before using Upgrade transcript in Sessions."
        guard sidecarMissing else { return base }
        return base + " The notes file for /meeting was not written either; Upgrade transcript in Sessions writes it from the session folder."
    }
}
