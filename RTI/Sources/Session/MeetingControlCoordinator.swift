import AppKit
import Foundation
import Observation
import RTICore
import UniformTypeIdentifiers

/// RTI's meeting control plane. Meeting Sentinel owns durable recording and
/// post-meeting processing; SessionCoordinator owns opt-in live intelligence.
@Observable @MainActor
final class MeetingControlCoordinator {
    static let shared = MeetingControlCoordinator()

    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var lastError: String?

    private init() {}

    var sentinelMeeting: SentinelMeeting? {
        MeetingSentinelMonitor.shared.liveMeeting
    }

    var isRecording: Bool { sentinelMeeting != nil }
    var isLive: Bool { SessionCoordinator.shared.isRunning }

    var selectedProjectName: String? {
        guard MeetingContextStore.shared.workstreamItem?.isProject == true else { return nil }
        return MeetingContextStore.shared.workstreamName
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isBusy, !isRecording else { return }
        let descriptor = currentDescriptor()
        run(
            SentinelCommandBuilder.start(
                name: descriptor.name,
                project: descriptor.projectSlug
            ),
            progress: "Starting Sentinel recording…"
        ) { [weak self] result in
            self?.finish(result, success: "Sentinel is recording.")
        }
    }

    /// End the meeting's keeper-of-record. If RTI is live, finish that
    /// provisional session first; Sentinel then transcribes and processes the
    /// definitive recording in the background.
    func stopRecording() {
        guard !isBusy, isRecording else { return }
        if SessionCoordinator.shared.isRunning {
            SessionCoordinator.shared.stopSession()
        }
        // Pass the project again at stop: a mid-recording pick would otherwise
        // be lost, since start already wrote the manifest (or wrote no project).
        run(
            SentinelCommandBuilder.stop(project: currentDescriptor().projectSlug),
            progress: "Stopping and sending for transcription…"
        ) { [weak self] result in
            self?.finish(result, success: "Recording stopped. Transcription is running.")
        }
    }

    func toggleLiveIntelligence() {
        let session = SessionCoordinator.shared
        if session.isRunning {
            session.stopSession()
            return
        }
        guard let meeting = sentinelMeeting else {
            lastError = "Start a Sentinel recording before going live with RTI."
            return
        }
        session.startSession(linkedTo: meeting, userInitiated: true)
        WindowCoordinator.shared.showOverlay()
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.assist.rawValue)
    }

    func chooseProject() {
        WindowCoordinator.shared.showOverlay()
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.setup.rawValue)
    }

    func importAudio() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import audio for Meeting Sentinel"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        run(
            SentinelCommandBuilder.transcribe(
                file: url.path,
                project: currentDescriptor().projectSlug
            ),
            progress: "Transcribing imported audio…"
        ) { [weak self] result in
            self?.finish(result, success: "Imported audio was transcribed and processed.")
        }
    }

    private func currentDescriptor() -> (name: String, projectSlug: String?) {
        let context = MeetingContextStore.shared
        let title = context.calendarMeeting?.title
            ?? context.workstreamName
            ?? "meeting-\(Self.timestamp.string(from: Date()))"
        let project = context.workstreamItem.flatMap { item in
            item.isProject ? item.url.lastPathComponent : nil
        }
        return (title, project)
    }

    private func run(
        _ arguments: [String],
        progress: String,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        guard let executable = SentinelPaths.executableURL() else {
            lastError = "Meeting Sentinel isn't installed at ~/.local/bin/meet."
            return
        }

        isBusy = true
        lastError = nil
        statusMessage = progress

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let key = CredentialStore.soniox, !key.isEmpty {
            environment["SONIOX_API_KEY"] = key
        }
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { process in
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let text = [stdout, stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result: Result<String, Error> = process.terminationStatus == 0
                ? .success(text)
                : .failure(SentinelControlError.commandFailed(text.isEmpty ? "Meeting Sentinel failed." : text))
            Task { @MainActor in completion(result) }
        }

        do {
            try process.run()
        } catch {
            isBusy = false
            statusMessage = nil
            lastError = error.localizedDescription
        }
    }

    private func finish(_ result: Result<String, Error>, success: String) {
        isBusy = false
        MeetingSentinelMonitor.shared.refresh()
        switch result {
        case .success:
            statusMessage = success
            lastError = nil
        case .failure(let error):
            statusMessage = nil
            lastError = error.localizedDescription
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

private enum SentinelControlError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): detail
        }
    }
}
