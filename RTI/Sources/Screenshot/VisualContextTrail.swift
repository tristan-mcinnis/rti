import AppKit
import CoreGraphics
import Foundation
import Observation
import RTICore

/// Session-scoped ambient screen context. Samples only while RTI is recording
/// and keeps OCR text in memory. When the `local_vision` lane is enabled, each
/// accepted frame is also staged as a compressed JPEG for the session archive
/// (`frames/`), and — with `ambient_describe` on — described by the local
/// vision model at 127.0.0.1. With the lane disabled, images are discarded
/// inside ScreenshotManager immediately after Vision OCR, as before.
@Observable @MainActor
final class VisualContextTrail {
    static let shared = VisualContextTrail()

    enum State: Equatable {
        case disabled
        case idle
        case waiting
        case capturing
        case active
        case paused
        case permissionRequired
        case failed
    }

    private(set) var state: State
    private(set) var events: [VisualContextEvent] = []
    private(set) var lastError: String?

    var isEnabled: Bool {
        ScreenshotPolicy.shared.effective == .automatic
    }

    private var sessionStartedAt: Date?
    private var captureTask: Task<Void, Never>?
    private var lastCapturedText: String?
    private var descriptions: [UUID: Task<Void, Never>] = [:]
    private var contextStart = 0

    private init() {
        state = .idle
    }

    func start(sessionStartedAt: Date) {
        ScreenshotPolicy.shared.automaticStateChanged()
        cancelWork()
        events = []
        contextStart = 0
        lastCapturedText = nil
        lastError = nil
        self.sessionStartedAt = sessionStartedAt

        guard isEnabled else {
            state = .disabled
            return
        }
        state = .waiting
        scheduleCaptureLoop(captureImmediately: true)
    }

    func stopCapturing() {
        ScreenshotPolicy.shared.automaticStateChanged()
        cancelWork()
        sessionStartedAt = nil
        state = isEnabled ? .idle : .disabled
    }

    func setPaused(_ paused: Bool) {
        ScreenshotPolicy.shared.automaticStateChanged()
        guard sessionStartedAt != nil, isEnabled else { return }
        if paused {
            cancelWork()
            state = .paused
        } else {
            state = .waiting
            scheduleCaptureLoop(captureImmediately: true)
        }
    }

    private func cancelWork() {
        captureTask?.cancel()
        captureTask = nil
        for task in descriptions.values { task.cancel() }
        descriptions.removeAll()
    }

    func refreshPolicy() {
        cancelWork()
        lastError = nil
        lastCapturedText = nil
        contextStart = events.count
        guard isEnabled else { state = .disabled; return }
        guard sessionStartedAt != nil, SessionCoordinator.shared.isRunning else { state = .idle; return }
        setPaused(SessionCoordinator.shared.isPaused)
    }

    func recentPromptContext() -> String? {
        guard ScreenshotPolicy.shared.allows(.automatic) else { return nil }
        return VisualContextText.promptContext(events: Array(events.dropFirst(contextStart)))
    }

    /// A screen or window screenshot (`capture_screen`, ⌘⇧H, ⌘⇧J) made while a
    /// session is live: give it a home in the trail so its frame and vision
    /// summary reach the archive.
    /// `lastCapturedText` is deliberately untouched — a manual capture must
    /// not suppress the next ambient sample.
    func recordExternalCapture(
        offsetSeconds: Int,
        text: String,
        visionSummary: String?,
        frameFilename: String?
    ) {
        guard sessionStartedAt != nil, ScreenshotPolicy.shared.allows(.manual) else { return }
        guard !text.isEmpty || visionSummary != nil else { return }
        events.append(VisualContextEvent(
            offsetSeconds: offsetSeconds,
            text: text.isEmpty ? "(no machine-readable text on screen)" : text,
            visionSummary: visionSummary,
            frameFilename: frameFilename
        ))
        trimEventsIfNeeded()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleCaptureLoop(captureImmediately: Bool) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            if captureImmediately { await captureOnce() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: VisualContextSettingsDefaults.captureIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                await captureOnce()
            }
        }
    }

    private func captureOnce() async {
        guard let permit = try? ScreenshotPolicy.shared.permit(for: .automatic), let sessionStartedAt else { return }
        state = .capturing
        do {
            let visionConfig = LocalVisionConfiguration.from(VaultPaths.configDictionary())
            let wantsFrame = visionConfig.enabled
                && (visionConfig.saveFrames || visionConfig.ambientDescribe)
            let frame = try await ScreenshotManager.shared.captureActiveDisplayFrame(includeFrame: wantsFrame)
            // A capture takes about a second of OCR. If the recording paused
            // or stopped meanwhile, that already set the state; writing
            // `.active` over it showed "Screen context on" on a paused or
            // finished session.
            try ScreenshotPolicy.shared.check(permit)
            let text = VisualContextText.compact(frame.text)
            if VisualContextText.isMeaningfullyDifferent(text, from: lastCapturedText) {
                let offset = Int(Date().timeIntervalSince(sessionStartedAt))
                var frameFilename: String?
                if visionConfig.enabled, visionConfig.saveFrames, let jpeg = frame.frameJPEG {
                    let staging = VisualFrameStore.stagingDirectory(
                        configHome: VaultPaths.homeDirectory(),
                        startedAt: sessionStartedAt
                    )
                    frameFilename = try? VisualFrameStore.writeFrame(
                        jpeg,
                        offsetSeconds: offset,
                        trigger: "ambient",
                        stagingDirectory: staging
                    )
                }
                let event = VisualContextEvent(
                    offsetSeconds: offset,
                    text: text,
                    frameFilename: frameFilename
                )
                events.append(event)
                trimEventsIfNeeded()
                lastCapturedText = text
                if visionConfig.enabled, visionConfig.ambientDescribe, let jpeg = frame.frameJPEG {
                    describeInBackground(jpeg: jpeg, eventID: event.id, configuration: visionConfig, permit: permit)
                }
            }
            lastError = nil
            state = .active
        } catch {
            guard !Task.isCancelled else { return }
            let nsError = error as NSError
            if nsError.domain.contains("ScreenCaptureKit") || nsError.domain.contains("TCC") {
                state = .permissionRequired
                lastError = "Screen Recording access is off."
                captureTask?.cancel()
                captureTask = nil
            } else if let screenshotError = error as? ScreenshotError,
                      case .empty = screenshotError {
                state = .active
            } else {
                state = .failed
                lastError = "Screen context paused: \(nsError.localizedDescription)"
            }
        }
    }

    private func trimEventsIfNeeded() {
        if events.count > VisualContextSettingsDefaults.maximumEventCount {
            let excess = events.count - VisualContextSettingsDefaults.maximumEventCount
            events.removeFirst(excess)
            contextStart = max(0, contextStart - excess)
        }
    }

    /// The description must never delay the capture loop, so it lands on the
    /// event after the fact — the prompt, archive, and summary readers all
    /// pick it up from the updated event.
    private func describeInBackground(
        jpeg: Data,
        eventID: UUID,
        configuration: LocalVisionConfiguration,
        permit: ScreenshotPolicy.Permit
    ) {
        descriptions[eventID] = Task { [weak self] in
            defer { self?.descriptions[eventID] = nil }
            guard (try? ScreenshotPolicy.shared.check(permit)) != nil else { return }
            guard let summary = try? await LocalVisionService.describe(
                imageData: jpeg,
                configuration: configuration
            ) else { return }
            guard (try? ScreenshotPolicy.shared.check(permit)) != nil else { return }
            self?.attachVisionSummary(summary, to: eventID)
        }
    }

    private func attachVisionSummary(_ summary: String, to id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index] = events[index].withVisionSummary(summary)
    }
}
