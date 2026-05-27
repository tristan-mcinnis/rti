import Foundation

/// Common lifecycle for session-scoped analysis controllers that run periodic
/// LLM passes against the live transcript and publish results. Notes and
/// Dossiers follow this shape exactly; DiscussionGuideController is a
/// near-match (its scheduler entry point is `match` rather than `generate`,
/// but the lifecycle is the same).
///
/// Everything here is in-memory and ephemeral — there is no persistence.
/// `reset(for:)` simply binds a fresh session id and drops prior results;
/// `clear()` drops results without a new session.
@MainActor
protocol AnalysisController: AnyObject {
    /// True while an LLM pass is in flight. Conformers set this so the
    /// scheduler and UI can gate concurrent generation.
    var isGenerating: Bool { get set }

    /// Bind the controller to a session and drop any prior in-memory results.
    func reset(for sessionId: String)

    /// Drop in-memory state. Called when the active session is unloaded
    /// (e.g. user clears chat).
    func clear()

    /// Run one analysis pass over the transcript window starting at `sinceMs`
    /// (nil means "from the start of the session"). Returns the end-ms
    /// watermark so the scheduler can advance the window on the next tick,
    /// or nil if nothing was processed (empty window, guard gating, etc.).
    func generate(sessionId: String, sinceMs: Int?) async -> Int?
}
