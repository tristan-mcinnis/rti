import AVFoundation
import Foundation
import RTICore

struct TranscriptUpgradeProgress: Sendable {
    let message: String
    let isTerminal: Bool

    static func running(_ message: String) -> TranscriptUpgradeProgress {
        TranscriptUpgradeProgress(message: message, isTerminal: false)
    }

    static func done(_ message: String) -> TranscriptUpgradeProgress {
        TranscriptUpgradeProgress(message: message, isTerminal: true)
    }
}

enum TranscriptUpgradeError: LocalizedError {
    case missingAudio
    case missingCredentials(String)
    case missingScript(String)
    case providerFailed(String)
    case emptyTranscript(String)
    case unreadableTranscript
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudio:
            return "No retained audio found in this session folder."
        case .missingCredentials(let provider):
            return "\(provider) is missing required transcript-upgrade credentials."
        case .missingScript(let path):
            return "Transcript provider script is missing: \(path)"
        case .providerFailed(let detail):
            return detail
        case .emptyTranscript(let provider):
            return "\(provider) returned an empty transcript; the original transcript was left unchanged."
        case .unreadableTranscript:
            return "Couldn't read the original transcript."
        case .writeFailed(let detail):
            return "Couldn't write the upgraded transcript: \(detail)"
        }
    }
}

protocol AsyncTranscriptProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func transcribe(audioURL: URL, outputBaseURL: URL) async throws -> String
}

enum TranscriptUpgradeService {
    struct Result: Sendable {
        let provider: String
        let transcriptURL: URL
        let summaryURL: URL?
        let segmentCount: Int
    }

    static func upgrade(
        sessionDirectory: URL,
        startedAt: Date,
        provider option: AsyncTranscriptProviderOption? = nil,
        referenceContext: String? = nil,
        progress: @Sendable @escaping (TranscriptUpgradeProgress) -> Void
    ) async throws -> Result {
        try await upgrade(
            session: SessionArchive.ArchivedSession(
                url: sessionDirectory,
                transcriptURL: sessionDirectory.appendingPathComponent("transcript.md"),
                isRTIArchive: true,
                date: startedAt,
                title: nil,
                displayName: sessionDirectory.lastPathComponent
            ),
            provider: option,
            referenceContext: referenceContext,
            progress: progress
        )
    }

    static func upgrade(
        session: SessionArchive.ArchivedSession,
        provider option: AsyncTranscriptProviderOption? = nil,
        referenceContext: String? = nil,
        progress: @Sendable @escaping (TranscriptUpgradeProgress) -> Void
    ) async throws -> Result {
        let provider = try makeProvider(option ?? AsyncTranscriptProviders.active)
        progress(.running("Using \(provider.displayName)"))

        let pipelineResult: TranscriptUpgradeExecutionResult
        do {
            pipelineResult = try await TranscriptUpgradePipeline.upgrade(
                sessionDir: session.url,
                startedAt: session.date,
                providerID: provider.id,
                providerDisplayName: provider.displayName,
                frontmatter: session.date.map { SessionArchive.frontmatterForUpgrade(kind: "Transcript", startedAt: $0) } ?? [],
                progress: { message in progress(.running(message)) },
                transcribe: { audioURL, outputBaseURL in
                    try await provider.transcribe(audioURL: audioURL, outputBaseURL: outputBaseURL)
                },
                writeSummary: { transcriptText in
                    guard let startedAt = session.date else { return nil }
                    return await SessionArchive.writeAutoSummary(
                        transcriptText: transcriptText,
                        to: session.url,
                        startedAt: startedAt,
                        referenceContext: referenceContext
                    )
                },
                runRouter: {
                    SessionArchive.runVaultRouter(sessionDir: session.url)
                }
            )
        } catch {
            throw mapPipelineError(error)
        }
        if let startedAt = session.date,
           let canonicalURL = SessionArchive.refreshCanonicalMeetingTranscript(fromArchiveDir: session.url, startedAt: startedAt) {
            SessionArchive.runMeetingProcessor(transcriptURL: canonicalURL)
        }
        progress(.done(pipelineResult.summaryURL == nil
            ? "Upgraded with \(provider.displayName); summary regeneration failed"
            : "Upgraded with \(provider.displayName); summary regenerated"))

        return Result(
            provider: provider.displayName,
            transcriptURL: pipelineResult.transcriptURL,
            summaryURL: pipelineResult.summaryURL,
            segmentCount: pipelineResult.segmentCount
        )
    }

    private static func makeProvider(_ option: AsyncTranscriptProviderOption) throws -> AsyncTranscriptProvider {
        switch option.id {
        case AsyncTranscriptProviders.soniox.id:
            return try makeSonioxProvider()
        case AsyncTranscriptProviders.aliyun.id:
            let missing = aliyunMissingCredentials()
            guard missing.isEmpty else {
                throw TranscriptUpgradeError.missingCredentials("Aliyun (\(missing.joined(separator: ", ")))")
            }
            return AliyunScriptTranscriptProvider(
                accessKeyId: CredentialStore.aliyunAccessKeyID ?? "",
                accessKeySecret: CredentialStore.aliyunAccessKeySecret ?? "",
                appKey: CredentialStore.aliyunNLSAppKey ?? ""
            )
        default:
            return try makeSonioxProvider()
        }
    }

    private static func makeSonioxProvider() throws -> AsyncTranscriptProvider {
        guard !(CredentialStore.soniox ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptUpgradeError.missingCredentials(AsyncTranscriptProviders.soniox.displayName)
        }
        return SonioxScriptTranscriptProvider(apiKey: CredentialStore.soniox ?? "")
    }

    private static func aliyunMissingCredentials() -> [String] {
        [
            ("Access Key ID", CredentialStore.aliyunAccessKeyID),
            ("Access Key Secret", CredentialStore.aliyunAccessKeySecret),
            ("NLS App Key", CredentialStore.aliyunNLSAppKey),
        ].compactMap { label, value in
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? label : nil
        }
    }

    static func audioInputs(in dir: URL) -> [TranscriptUpgradeAudioInput] {
        TranscriptUpgradeAudioDiscovery.inputs(in: dir)
    }

    /// Total duration of the retained audio legs, for the "is this a real
    /// session or a test blip" judgment. 0 when unreadable.
    static func retainedAudioSeconds(in dir: URL) -> TimeInterval {
        audioInputs(in: dir).reduce(0) { total, input in
            guard let file = try? AVAudioFile(forReading: input.url) else { return total }
            let rate = file.processingFormat.sampleRate
            guard rate > 0 else { return total }
            return total + Double(file.length) / rate
        }
    }

    private static func mapPipelineError(_ error: Error) -> Error {
        if let upgradeError = error as? TranscriptUpgradeError {
            return upgradeError
        }
        guard let pipelineError = error as? TranscriptUpgradePipelineError else {
            return TranscriptUpgradeError.writeFailed(error.localizedDescription)
        }
        switch pipelineError {
        case .missingAudio:
            return TranscriptUpgradeError.missingAudio
        case .unreadableTranscript:
            return TranscriptUpgradeError.unreadableTranscript
        case .emptyTranscript(let provider):
            return TranscriptUpgradeError.emptyTranscript(provider)
        case .missingSessionDate:
            return TranscriptUpgradeError.writeFailed("session folder name is not a timestamp")
        }
    }

}

private struct SonioxScriptTranscriptProvider: AsyncTranscriptProvider {
    let id = "soniox_file"
    let displayName = "Soniox"
    let apiKey: String
    /// `soniox_file_script` in `~/.config/rti/config.json`, else the default
    /// checkout location under the user's home.
    private let script = TranscriptUpgradeScripts.path(
        configKey: "soniox_file_script",
        default: "Documents/code/file-transcriber/skills/file-transcriber/scripts/transcribe-soniox.py"
    )

    func transcribe(audioURL: URL, outputBaseURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: script) else {
            throw TranscriptUpgradeError.missingScript(script)
        }
        let output = outputBaseURL.appendingPathExtension("soniox.txt")
        try await ScriptRunner.run(
            executable: ExternalTools.systemPython.path,
            arguments: [script, "-f", audioURL.path, "-l", "en", "zh", "--format", "txt", "-o", output.path],
            environment: ["SONIOX_API_KEY": apiKey]
        )
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }
}

private struct AliyunScriptTranscriptProvider: AsyncTranscriptProvider {
    let id = "aliyun_file"
    let displayName = "Aliyun"
    let accessKeyId: String
    let accessKeySecret: String
    let appKey: String
    /// `aliyun_file_script` in `~/.config/rti/config.json`, else the default
    /// checkout location under the user's home.
    private let script = TranscriptUpgradeScripts.path(
        configKey: "aliyun_file_script",
        default: "Documents/code/archive/aliyun-stt/scripts/aliyun_filetrans.py"
    )

    func transcribe(audioURL: URL, outputBaseURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: script) else {
            throw TranscriptUpgradeError.missingScript(script)
        }
        let rawOutput = outputBaseURL.appendingPathExtension("aliyun.json")
        let textOutput = outputBaseURL.appendingPathExtension("aliyun.txt")
        try await ScriptRunner.run(
            executable: ExternalTools.systemPython.path,
            arguments: [script, "--audio", audioURL.path, "--raw-output", rawOutput.path, "--text-output", textOutput.path],
            environment: [
                "ALIBABA_CLOUD_ACCESS_KEY_ID": accessKeyId,
                "ALIBABA_CLOUD_ACCESS_KEY_SECRET": accessKeySecret,
                "NLS_APP_KEY": appKey
            ]
        )
        return (try? String(contentsOf: textOutput, encoding: .utf8)) ?? ""
    }
}

/// Where the offline transcript-provider scripts live. One config file
/// (`~/.config/rti/config.json`) anchors every path RTI touches; these two
/// keys let the checkouts move without a rebuild.
private enum TranscriptUpgradeScripts {
    static func path(configKey: String, default homeRelative: String) -> String {
        if let configured = VaultPaths.configDictionary()[configKey] as? String, !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(homeRelative).path
    }
}

private enum ScriptRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 3_600
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = ScriptRunState()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                guard state.markFinished() else { return }
                continuation.resume(throwing: TranscriptUpgradeError.providerFailed(error.localizedDescription))
                return
            }

            // Drain both pipes while the child runs. Reading them only after
            // exit let a chatty provider fill a pipe and block forever, until
            // the timeout killed it.
            let output = ProcessOutputCollector(stdout: stdout, stderr: stderr)
            let timeoutTask = DispatchWorkItem {
                guard state.markFinished() else { return }
                if process.isRunning { process.terminate() }
                continuation.resume(throwing: TranscriptUpgradeError.providerFailed("Transcript provider timed out after \(Int(timeout)) seconds."))
            }
            state.setTimeout(timeoutTask)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutTask)

            DispatchQueue.global(qos: .utility).async {
                let (outData, data) = output.wait()
                process.waitUntilExit()
                state.cancelTimeout()
                guard state.markFinished() else { return }
                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Keep both streams: Python warnings land on stderr and would
                // otherwise mask the actual error printed on stdout.
                let detail = [err, out].filter { !$0.isEmpty }.joined(separator: "\n")
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscriptUpgradeError.providerFailed(detail.isEmpty ? "Transcript provider exited with \(process.terminationStatus)." : detail))
                }
            }
        }
    }
}

private final class ScriptRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timeoutTask: DispatchWorkItem?

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    func setTimeout(_ task: DispatchWorkItem) {
        lock.lock()
        timeoutTask = task
        lock.unlock()
    }

    func cancelTimeout() {
        lock.lock()
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
    }
}
