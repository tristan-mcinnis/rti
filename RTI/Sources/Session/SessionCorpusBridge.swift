import Foundation

/// Session-end corpus bridge: opens the live JSONL stream on launch,
/// flushes it on emergency shutdown, and triggers the async title →
/// summary → themes → markdown render chain when a session completes.
///
/// Extracted from `SessionCoordinator` so the render-trigger concern
/// doesn't interleave with mic-permission UX and audio lifecycle.
@MainActor
final class SessionCorpusBridge {

    /// Open the live JSONL stream for a freshly-launched session.
    func openLive(sessionId: String) {
        LiveSessionStore.shared.openLive(sessionId: sessionId)
    }

    /// Best-effort flush of the live JSONL for emergency (app-terminate)
    /// shutdown. Remaining audio is already on disk via WAV; transcript
    /// finals for the last second or two may be lost, which beats
    /// truncating the WAV header.
    func flushLive(sessionId: String) {
        LiveSessionStore.shared.closeLive(sessionId: sessionId)
    }

    /// Trigger the async title-gen → summary-gen → themes → markdown-render
    /// chain for a completed session. Skips the render if the session has
    /// no content (empty JSONL).
    func triggerSummary(
        sessionId: String,
        startedAt: Date?,
        endedAt: Date?,
        wavPath: String?,
        modeId: String?
    ) {
        let liveURL = LiveSessionStore.shared.liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let hasContent: Bool = {
            guard FileManager.default.fileExists(atPath: liveURL.path) else { return false }
            guard let events = try? LiveJSONLReader.readAll(liveURL) else { return false }
            return events.contains(where: {
                if case .word(_, _, _, true, _, _) = $0 { return true }
                if case .note = $0 { return true }
                return false
            })
        }()

        let renderStartedAt = startedAt ?? Date()

        if !hasContent { return }

        Task { @MainActor in
            async let title: String? = SessionTitleController.shared.generateTitle(for: sessionId)
            async let summary: SessionSummary? = SummaryController.shared.generateSummary(for: sessionId)
            async let themesDone: Void = ThemesController.shared.generateHiFi(sessionId: sessionId)
            _ = await (title, summary, themesDone)
            await CorpusManager.shared.renderSession(
                sessionId: sessionId,
                startedAt: renderStartedAt,
                endedAt: endedAt,
                wavPath: wavPath,
                modeId: modeId
            )
            NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
        }
    }
}
