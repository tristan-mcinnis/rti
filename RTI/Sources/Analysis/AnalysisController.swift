import Foundation

/// Common lifecycle for session-scoped analysis controllers that run periodic
/// LLM passes against the live transcript and publish results. Three
/// controllers (Notes, Dossiers, Themes) follow this shape exactly;
/// DiscussionGuideController is a near-match (its scheduler entry point is
/// `match` rather than `generate`, but the lifecycle is the same).
///
/// Conformers get:
///  - A discoverable contract — grep for `: AnalysisController` to find
///    every analysis module.
///  - A guarantee that the scheduler (`AnalysisScheduler`) can drive any
///    conformer without knowing its specific type.
@MainActor
protocol AnalysisController: AnyObject {
    /// Bind the controller to a session. Loads any persisted state for that
    /// session so the UI reflects prior analysis results immediately.
    func reset(for sessionId: String)

    /// Drop in-memory state without touching the database. Called when the
    /// active session is unloaded (e.g. user switches sessions, clears chat).
    func clear()

    /// Run one analysis pass over the transcript window starting at `sinceMs`
    /// (nil means "from the start of the session"). Returns the end-ms
    /// watermark so the scheduler can advance the window on the next tick,
    /// or nil if nothing was processed (empty window, guard gating, etc.).
    func generate(sessionId: String, sinceMs: Int?) async -> Int?
}
