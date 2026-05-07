import Foundation

/// Synthesises a `Session` value from the in-memory state of
/// `SessionCoordinator`. Used by `CorpusBackedStore` to present the
/// active session before it has been rendered to markdown.
@MainActor
enum ActiveSessionProjection {

    static func currentSession() -> Session? {
        guard let id = SessionCoordinator.shared.currentSessionId,
              let startedAt = SessionCoordinator.shared.startedAt else {
            return nil
        }
        return Session(
            id: id,
            startedAt: startedAt,
            endedAt: SessionCoordinator.shared.endedAt,
            wavPath: nil,
            notes: nil,
            title: nil,
            modeId: nil,
            calendarEventId: nil,
            calendarTitle: nil,
            transcriptQuality: nil
        )
    }
}
