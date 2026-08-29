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
        VisualContextSettingsDefaults.isEnabled
    }

    private var sessionStartedAt: Date?
    private var captureTask: Task<Void, Never>?
    private var lastCapturedText: String?

    private init() {
        state = VisualContextSettingsDefaults.isEnabled ? .idle : .disabled
    }

    func start(sessionStartedAt: Date) {
        captureTask?.cancel()
        events = []
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
        captureTask?.cancel()
        captureTask = nil
        state = isEnabled ? .idle : .disabled
    }

    func setPaused(_ paused: Bool) {
        guard sessionStartedAt != nil, isEnabled else { return }
        if paused {
            captureTask?.cancel()
            captureTask = nil
            state = .paused
        } else {
            state = .waiting
            scheduleCaptureLoop(captureImmediately: true)
        }
    }

    func setEnabled(_ enabled: Bool, sessionStartedAt: Date?) {
        VisualContextSettingsDefaults.isEnabled = enabled
        captureTask?.cancel()
        captureTask = nil
        lastError = nil

        guard enabled else {
            state = .disabled
            return
        }
        guard let sessionStartedAt else {
            state = .idle
            return
        }
        self.sessionStartedAt = sessionStartedAt
        state = .waiting
        scheduleCaptureLoop(captureImmediately: true)
    }

    func recentPromptContext() -> String? {
        VisualContextText.promptContext(events: events)
    }

    func summaryReferenceContext(maxCharacters: Int = 12_000) -> String? {
        VisualContextText.promptContext(
            events: events,
            maxEvents: events.count,
            maxCharacters: maxCharacters
        )
    }

    /// A ⌘⇧H / `capture_screen` capture made while a session is live: give it
    /// a home in the trail so its frame and vision summary reach the archive.
    /// `lastCapturedText` is deliberately untouched — a manual capture must
    /// not suppress the next ambient sample.
    func recordExternalCapture(
        offsetSeconds: Int,
        text: String,
        visionSummary: String?,
        frameFilename: String?
    ) {
        guard sessionStartedAt != nil else { return }
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

    func retryPermissionOrOpenSettings(sessionStartedAt: Date?) {
        if CGPreflightScreenCaptureAccess() {
            setEnabled(true, sessionStartedAt: sessionStartedAt)
        } else {
            openScreenRecordingSettings()
        }
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
        guard isEnabled, let sessionStartedAt else { return }
        state = .capturing
        do {
            let visionConfig = LocalVisionConfiguration.from(VaultPaths.configDictionary())
            let wantsFrame = visionConfig.enabled
                && (visionConfig.saveFrames || visionConfig.ambientDescribe)
            let frame = try await ScreenshotManager.shared.captureActiveDisplayFrame(includeFrame: wantsFrame)
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
                    describeInBackground(jpeg: jpeg, eventID: event.id, configuration: visionConfig)
                }
            }
            lastError = nil
            state = .active
        } catch {
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
            events.removeFirst(events.count - VisualContextSettingsDefaults.maximumEventCount)
        }
    }

    /// The description must never delay the capture loop, so it lands on the
    /// event after the fact — the prompt, archive, and summary readers all
    /// pick it up from the updated event.
    private func describeInBackground(
        jpeg: Data,
        eventID: UUID,
        configuration: LocalVisionConfiguration
    ) {
        Task { [weak self] in
            guard let summary = try? await LocalVisionService.describe(
                imageData: jpeg,
                configuration: configuration
            ) else { return }
            self?.attachVisionSummary(summary, to: eventID)
        }
    }

    private func attachVisionSummary(_ summary: String, to id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index] = events[index].withVisionSummary(summary)
    }
}
