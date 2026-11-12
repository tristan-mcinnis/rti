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
    case alreadyUpgrading

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
        case .alreadyUpgrading:
            return "This session's transcript upgrade is already running."
        }
    }
}

protocol AsyncTranscriptProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func transcribe(audioURL: URL, outputBaseURL: URL) async throws -> String
}

enum TranscriptUpgradeService {
    @MainActor private static var upgradingGuides: Set<URL> = []
    struct Result: Sendable {
        let provider: String
        let transcriptURL: URL
        let segmentCount: Int
    }

    static func upgrade(
        sessionDirectory: URL,
        startedAt: Date,
        provider option: AsyncTranscriptProviderOption? = nil,
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
            progress: progress
        )
    }

    @MainActor static func upgrade(
        session: SessionArchive.ArchivedSession,
        provider option: AsyncTranscriptProviderOption? = nil,
        progress: @Sendable @escaping (TranscriptUpgradeProgress) -> Void
    ) async throws -> Result {
        let directory = session.url.standardizedFileURL
        let guided = FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.live.md").path)
        if guided, !upgradingGuides.insert(directory).inserted { throw TranscriptUpgradeError.alreadyUpgrading }
        defer { if guided { upgradingGuides.remove(directory) } }
        return try await performUpgrade(session: session, option: option, progress: progress)
    }

    private struct PendingExport: Codable { let provider: String; let segmentCount: Int }
    private static let exportMarker = "canonical-export.pending.json"

    static func finishExport(in directory: URL, startedAt: Date, provider: String, segmentCount: Int) throws -> URL? {
        let marker = directory.appendingPathComponent(exportMarker)
        do {
            let url = try SessionArchive.requiredCanonicalExport(in: directory, startedAt: startedAt)
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            return url
        } catch {
            _ = SessionArchive.markAutomaticUpgradePending(in: directory)
            let data = try JSONEncoder().encode(PendingExport(provider: provider, segmentCount: segmentCount))
            try data.write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            throw error
        }
    }

    private static func performUpgrade(
        session: SessionArchive.ArchivedSession,
        option: AsyncTranscriptProviderOption?,
        progress: @Sendable @escaping (TranscriptUpgradeProgress) -> Void
    ) async throws -> Result {
        let pending = session.url.appendingPathComponent(exportMarker)
        if let date = session.date, FileManager.default.fileExists(atPath: pending.path) {
            let saved = try JSONDecoder().decode(PendingExport.self, from: Data(contentsOf: pending))
            if let url = try finishExport(in: session.url, startedAt: date, provider: saved.provider, segmentCount: saved.segmentCount) {
                SessionArchive.runMeetingProcessor(transcriptURL: url)
            }
            progress(.done("Raw transcript exported"))
            return Result(provider: saved.provider, transcriptURL: session.transcriptURL, segmentCount: saved.segmentCount)
        }
        let provider = try makeProvider(option ?? AsyncTranscriptProviders.active, sessionDirectory: session.url)
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
                }
            )
        } catch {
            throw mapPipelineError(error)
        }
        do {
            try await SessionArchive.reanchorGuide(in: session.url, upgradedTurns: pipelineResult.guideAnchorTurns)
        } catch {
            throw TranscriptUpgradeError.writeFailed(error.localizedDescription)
        }
        if let startedAt = session.date,
           let canonicalURL = try finishExport(in: session.url, startedAt: startedAt, provider: provider.displayName, segmentCount: pipelineResult.segmentCount) {
            SessionArchive.runMeetingProcessor(transcriptURL: canonicalURL)
        }
        progress(.done("Upgraded with \(provider.displayName)"))

        return Result(
            provider: provider.displayName,
            transcriptURL: pipelineResult.transcriptURL,
            segmentCount: pipelineResult.segmentCount
        )
    }

    /// The automatic pass after a recording: one more try if the provider
    /// failed, so a network wobble needs no manual step. Audio is kept either way.
    @MainActor
    static func upgradeRetryingOnce(
        sessionDirectory: URL,
        startedAt: Date,
        provider option: AsyncTranscriptProviderOption,
        progress: @Sendable @escaping (TranscriptUpgradeProgress) -> Void
    ) async throws -> Result {
        try await RetryOnce.run(delay: .seconds(30), shouldRetry: { error in
            guard case TranscriptUpgradeError.providerFailed = error else { return false }
            RTILog.log("transcript upgrade failed, retrying once: \(error.localizedDescription)", category: .archive)
            progress(.running("Retrying transcript…"))
            return true
        }, operation: {
            try await upgrade(
                sessionDirectory: sessionDirectory,
                startedAt: startedAt,
                provider: option,
                progress: progress
            )
        })
    }

    private static func makeProvider(
        _ option: AsyncTranscriptProviderOption,
        sessionDirectory: URL
    ) throws -> AsyncTranscriptProvider {
        // Soniox is the one upgrade provider. The Aliyun option was removed
        // on 2026-09-26: its NLS script no longer exists on this Mac.
        guard !(CredentialStore.soniox ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptUpgradeError.missingCredentials(AsyncTranscriptProviders.soniox.displayName)
        }
        return SonioxScriptTranscriptProvider(
            apiKey: CredentialStore.soniox ?? "",
            context: speechContext(in: sessionDirectory)
        )
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

    private static func speechContext(in sessionDirectory: URL) -> SonioxContext? {
        guard let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent("session.json")) else { return nil }
        return (try? JSONDecoder().decode(SessionArchiveMetadata.self, from: data))?.speechContext
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
    let context: SonioxContext?
    /// `soniox_file_script` in `~/.config/rti/config.json`, else the default
    /// checkout location under the user's home.
    private let script = TranscriptUpgradeScripts.path(
        configKey: "soniox_file_script",
        default: "skills/file-transcriber/scripts/transcribe-soniox.py"
    )

    func transcribe(audioURL: URL, outputBaseURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: script) else {
            throw TranscriptUpgradeError.missingScript(script)
        }
        let output = outputBaseURL.appendingPathExtension("soniox.txt")
        var arguments = [script, "-f", audioURL.path, "-l", "en", "zh", "--format", "txt", "-o", output.path]
        let contextFile = outputBaseURL.appendingPathExtension("soniox-context.json")
        defer { try? FileManager.default.removeItem(at: contextFile) }
        if let context {
            try JSONEncoder().encode(context).write(to: contextFile)
            arguments += ["--context-file", contextFile.path]
        }
        try await ScriptRunner.run(
            executable: ExternalTools.systemPython.path,
            arguments: arguments,
            environment: ["SONIOX_API_KEY": apiKey]
        )
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }
}

/// Where the offline transcript-provider scripts live. One config file
/// (`~/.config/rti/config.json`) anchors every path RTI touches; its
/// `soniox_file_script` key lets the checkout move without a rebuild.
private enum TranscriptUpgradeScripts {
    static func path(configKey: String, default homeRelative: String) -> String {
        if let configured = VaultPaths.configDictionary()[configKey] as? String, !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(homeRelative).path
    }
}

enum ScriptRunner {
    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 1_800
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                    return
                }
                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Keep both streams: Python warnings land on stderr and would
                // otherwise mask the actual error printed on stdout.
                let detail = [err, out].filter { !$0.isEmpty }.joined(separator: "\n")
                continuation.resume(throwing: TranscriptUpgradeError.providerFailed(detail.isEmpty ? "Process exited with \(process.terminationStatus)." : detail))
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
