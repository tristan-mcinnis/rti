import Foundation

/// Fire-and-forget bridge to the vault-side voice-profile flywheel: when the
/// user confirms speaker names (Save in the Sessions browser writes
/// speaker-names.json), ask the vault tool to enroll that session's confirmed
/// voices so future sessions can be suggested automatically. Best-effort and
/// silent, mirroring `SessionArchive.runVaultRouter`: a missing tool, model,
/// or python stack is a no-op. Policy, gates, and embeddings all stay
/// vault-side — the app only pulls the trigger the human already squeezed.
enum SpeakerEnrollment {
    static func fireAndForget(sessionDir: URL) {
        guard let script = speakerProfilesScriptURL(),
              let python = ExternalTools.stackPython() else { return }
        ExternalTools.launchDetached(python, arguments: [script.path, "enroll-from-session", sessionDir.path])
    }

    /// Vault-side speaker-profiles CLI, when the vault is reachable. Shared
    /// with Settings › Voices, which drives the same tool for sample review.
    /// Needs the embedding stack (sherpa-onnx), hence `ExternalTools.stackPython`.
    static func speakerProfilesScriptURL() -> URL? {
        VaultPaths.vaultToolURL(".claude/tools/pipeline/speaker-profiles.py")
    }
}
