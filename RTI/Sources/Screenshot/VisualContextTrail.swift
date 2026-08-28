import AppKit
import CoreGraphics
import Foundation
import Observation
import RTICore

/// Session-scoped ambient screen context. Samples only while RTI is recording,
/// keeps OCR text in memory, and leaves image persistence to nobody: the image
/// is discarded inside ScreenshotManager immediately after Vision OCR.
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
            let raw = try await ScreenshotManager.shared.captureActiveDisplayDescription()
            let text = VisualContextText.compact(raw)
            if VisualContextText.isMeaningfullyDifferent(text, from: lastCapturedText) {
                events.append(VisualContextEvent(
                    offsetSeconds: Int(Date().timeIntervalSince(sessionStartedAt)),
                    text: text
                ))
                if events.count > VisualContextSettingsDefaults.maximumEventCount {
                    events.removeFirst(events.count - VisualContextSettingsDefaults.maximumEventCount)
                }
                lastCapturedText = text
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
}
