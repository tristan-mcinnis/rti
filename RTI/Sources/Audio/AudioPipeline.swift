import AppKit
import AVFoundation
import Foundation

/// Owns the full audio capture → WAV + Soniox pipeline for both mic and
/// system audio. Hides the dual-channel complexity behind a small interface:
/// prepare, start, finalize, finish, abort.
@MainActor
final class AudioPipeline {

    var onWords: (([SonioxWord]) -> Void)?
    var onSystemWords: (([SonioxWord]) -> Void)?
    /// Fires on terminal mic-audio failures. `isAuth` gates the "Open Settings"
    /// affordance in the UI.
    var onError: ((String, Bool) -> Void)?

    private let audio = AudioCaptureManager()
    private let systemAudio = SystemAudioCapture()
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var systemSoniox: SonioxClient?

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AudioCaptureManager().requestPermission(completion)
    }

    /// Create the WAV file and the mic Soniox client. Does **not** start
    /// capture yet — call `start()` after this returns.
    /// - Returns: the URL of the WAV file being prepared.
    var translationConfig: TranslationConfig?

    /// Proper nouns from past meetings, sent to Soniox as `context.terms`
    /// to bias recognition of names/brands/orgs. Set before `prepare`.
    var contextTerms: [String] = []

    func prepare(sessionId: String) throws -> URL {
        // Fast-fail before opening a WAV on disk: a missing/empty Soniox
        // key would otherwise let the user "record" silently for 5 retries
        // before any error surfaces, leaving an orphan WAV in the corpus.
        guard !Secrets.sonioxAPIKey.isEmpty else {
            throw AudioPipelineError.missingSonioxKey
        }

        let wavURL = WAVWriter.defaultURL(for: sessionId)
        try wav.open(at: wavURL)

        let client = SonioxClient(
            apiKey: Secrets.sonioxAPIKey,
            url: SonioxClient.defaultURL,
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        client.onWords = { [weak self] words in self?.onWords?(words) }
        client.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        client.connect()
        self.soniox = client

        audio.onPCMBuffer = { [weak self] buffer in
            self?.wav.append(buffer)
            guard let int16 = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let byteCount = frameLength * MemoryLayout<Int16>.size
            let data = Data(bytes: int16[0], count: byteCount)
            self?.soniox?.sendAudio(data)
        }

        return wavURL
    }

    /// Start mic capture immediately; system audio starts asynchronously
    /// (non-fatal if it fails).
    func start() throws {
        try audio.start()

        // Don't even attempt the system-audio Soniox leg without a key.
        // The mic leg already enforces this in `prepare`; this guard
        // mirrors it so we don't silently consume Soniox credits on a
        // doomed second connection.
        guard !Secrets.sonioxAPIKey.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sysClient = SonioxClient(
                apiKey: Secrets.sonioxAPIKey,
                url: SonioxClient.defaultURL,
                translationConfig: translationConfig,
                contextTerms: contextTerms
            )
            sysClient.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sysClient.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                let message = failure.userMessage(didOpen: didOpen)
                RTILog.log("system audio Soniox error — \(message)", category: "soniox")
                // System-audio failure is non-fatal for the session (mic
                // continues). Surface it once via the same `onError`
                // callback the mic leg uses, with `isAuth=false` so the
                // UI banner is informational rather than recommending
                // Settings (the mic side already would have for an auth
                // error).
                if failure.isAuth {
                    self.onError?("System audio: \(message)", false)
                }
            }
            sysClient.connect()
            self.systemSoniox = sysClient

            self.systemAudio.onPCMBuffer = { [weak self] buffer in
                guard let int16 = buffer.int16ChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                let byteCount = frameLength * MemoryLayout<Int16>.size
                let data = Data(bytes: int16[0], count: byteCount)
                self?.systemSoniox?.sendAudio(data)
            }
            self.systemAudio.onError = { msg in
                RTILog.log("system audio capture error — \(msg)", category: "audio")
            }
            do {
                try await self.systemAudio.start()
            } catch {
                RTILog.log("system audio start failed — \(error)", category: "audio")
            }
        }
    }

    /// Stop capture and signal end-of-audio to Soniox. Call `finish()`
    /// after the 1.5 s finalize window to disconnect and close the WAV.
    func finalize() {
        audio.stop()
        systemAudio.stop()
        soniox?.finalize()
        systemSoniox?.finalize()
    }

    /// Disconnect Soniox and close the WAV file. Call after `finalize()`.
    func finish() {
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
    }

    /// Swap the Soniox transcription clients to apply a new translation
    /// config mid-session, without interrupting audio capture or losing the
    /// WAV file. Old clients are disconnected; new ones are created with
    /// the current `translationConfig` and immediately receive incoming
    /// PCM buffers via the existing `onPCMBuffer` closures.
    func reconfigureTranslation() {
        guard !Secrets.sonioxAPIKey.isEmpty else { return }

        // Mic leg.
        soniox?.disconnect()
        let mic = SonioxClient(
            apiKey: Secrets.sonioxAPIKey,
            url: SonioxClient.defaultURL,
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        mic.onWords = { [weak self] words in self?.onWords?(words) }
        mic.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        mic.connect()
        self.soniox = mic

        // System leg (if active).
        if systemSoniox != nil {
            systemSoniox?.disconnect()
            let sys = SonioxClient(
                apiKey: Secrets.sonioxAPIKey,
                url: SonioxClient.defaultURL,
                translationConfig: translationConfig,
                contextTerms: contextTerms
            )
            sys.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sys.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                if failure.isAuth {
                    self.onError?("System audio: \(failure.userMessage(didOpen: didOpen))", false)
                }
            }
            sys.connect()
            self.systemSoniox = sys
        }
    }

    /// Immediate teardown for failures and app termination.
    func abort() {
        audio.stop()
        systemAudio.stop()
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
    }
}

enum AudioPipelineError: LocalizedError {
    case missingSonioxKey

    var errorDescription: String? {
        switch self {
        case .missingSonioxKey:
            return "No Soniox API key set. Open Settings to paste a key, then start the session again."
        }
    }
}
