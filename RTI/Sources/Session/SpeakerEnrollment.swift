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
        guard let databases = VaultWorkstreamStore.databasesDir() else { return }
        let script = databases
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".claude/tools/pipeline/speaker-profiles.py")
        guard FileManager.default.fileExists(atPath: script.path),
              let python = pythonExecutableURL() else { return }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path, "enroll-from-session", sessionDir.path]
        try? proc.run()
    }

    /// The embedding stack (sherpa-onnx) lives in the user's python.org or
    /// Homebrew python, never Apple's /usr/bin/python3 — probe those first.
    /// The tool itself dies cleanly if the import is missing, so a wrong pick
    /// degrades to a silent no-op.
    private static func pythonExecutableURL() -> URL? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
