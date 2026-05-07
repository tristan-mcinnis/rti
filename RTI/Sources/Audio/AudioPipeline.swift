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

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AudioCaptureManager().requestPermission(completion)
    }

    /// Create the WAV file and the mic Soniox client. Does **not** start
    /// capture yet — call `start()` after this returns.
    /// - Returns: the URL of the WAV file being prepared.
    func prepare(sessionId: String) throws -> URL {
        let wavURL = WAVWriter.defaultURL(for: sessionId)
        try wav.open(at: wavURL)

        let client = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sysClient = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
            sysClient.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sysClient.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                let message = failure.userMessage(didOpen: didOpen)
                NSLog("[RTI] system audio Soniox error: \(message)")
                RTILog.log("system soniox error — \(message)", category: "soniox")
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
            self.systemAudio.onError = { [weak self] msg in
                NSLog("[RTI] system audio capture error: \(msg)")
                RTILog.log("system capture error — \(msg)", category: "audio")
            }
            do {
                try await self.systemAudio.start()
            } catch {
                NSLog("[RTI] system audio start failed: \(error)")
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
