import AppKit
import RTICore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// The primary display's OCR text plus, when the local-vision lane wants one,
/// a compressed JPEG of the frame. Consumed by the Visual Context Trail.
struct ActiveDisplayFrame {
    let text: String
    let frameJPEG: Data?
}

@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private static let maxOCRChars = 12_000
    private static let perScreenOCRChars = 6_000
    private struct CapturedScreenOCR {
        let label: String
        let isPrimary: Bool
        let text: String
        let regions: [ScreenTextRegion]
        let frameJPEG: Data?
    }

    private struct ScreenTextRegion {
        let text: String
        let rect: CGRect
        let screenLabel: String
    }

    private var lastCapturedRegions: [ScreenTextRegion] = []

    private init() {}

    private func visionConfiguration() -> LocalVisionConfiguration {
        LocalVisionConfiguration.from(VaultPaths.configDictionary())
    }

    /// Capture connected displays, OCR them (plus a local vision-model
    /// description when the `local_vision` lane is enabled), and attach the
    /// result to `LLMController` as pending screen context for the next turn.
    func captureAndAttach() {
        LLMController.shared.setScreenCaptureStatus("Reading all screens…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let combined = try await self.captureAndDescribe(trigger: "manual")
                LLMController.shared.attachScreenContext(combined)
            } catch ScreenshotError.empty {
                LLMController.shared.setScreenAttachError("No content found on the captured screen.")
            } catch {
                RTILog.log("Screenshot capture failed: \(error)", category: "screenshot")
                let msg = self.errorDescription(for: error)
                LLMController.shared.setScreenAttachError(msg)
                if Self.isScreenRecordingDenied(error) {
                    self.promptForScreenRecordingAccess()
                }
            }
        }
    }

    /// OCR an image the user dropped into the composer and attach the text as
    /// pending context for the next turn — the drag-and-drop sibling of
    /// `captureAndAttach()`. The chat provider itself is text-only; on-device
    /// Vision OCR extracts the text, and when the local-vision lane is enabled
    /// the image is also described by the local model (127.0.0.1) so charts
    /// and imagery survive the trip.
    func attachDroppedImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LLMController.shared.setScreenAttachError("Couldn't read that image.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let ocr = try await OCRService.recognizeText(in: cgImage)
                let trimmed = self.truncate(ocr)
                let visionConfig = self.visionConfiguration()
                var visionSummary: String?
                if visionConfig.enabled,
                   let jpeg = ScreenFrameEncoder.jpegData(from: cgImage) {
                    visionSummary = try? await LocalVisionService.describe(
                        imageData: jpeg,
                        prompt: "Describe this image in 2-4 short sentences: what it shows, any charts, diagrams, or visual detail. Do not transcribe the text itself.",
                        configuration: visionConfig
                    )
                }
                guard !trimmed.isEmpty || visionSummary != nil else {
                    LLMController.shared.setScreenAttachError("No readable text found in that image.")
                    return
                }
                var context = trimmed.isEmpty
                    ? "A dropped image with no machine-readable text."
                    : "Text from a dropped image:\n\(trimmed)"
                if let visionSummary {
                    context += "\n\nWhat the image looks like (local vision model): \(visionSummary)"
                }
                RTILog.log("Dropped image: OCR=\(trimmed.count) chars vision=\(visionSummary != nil).", category: "screenshot")
                LLMController.shared.attachScreenContext(context)
            } catch {
                RTILog.log("Dropped-image OCR failed: \(error)", category: "screenshot")
                LLMController.shared.setScreenAttachError("Couldn't read text from that image.")
            }
        }
    }

    /// Capture + OCR (+ local vision description when enabled) and return the
    /// combined context string. Throws `ScreenshotError.empty` if neither OCR
    /// nor the vision model produced anything. Used by the ⌘⇧H attach path and
    /// the LLM `capture_screen` tool. During a live session the primary frame
    /// is also staged into the session archive so the capture has a home.
    func captureAndDescribe(trigger: String = "manual") async throws -> String {
        LLMController.shared.setScreenCaptureStatus("Reading all screens…")
        do {
            let visionConfig = visionConfiguration()
            let screens = try await captureDisplaysWithOCR(
                activeOnly: false,
                includeFrame: visionConfig.enabled
            )
            let nonEmpty = screens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let primaryJPEG = screens.first?.frameJPEG

            var visionSummary: String?
            if visionConfig.enabled, let jpeg = primaryJPEG {
                LLMController.shared.setScreenCaptureStatus("Asking the local vision model…")
                do {
                    visionSummary = try await LocalVisionService.describe(
                        imageData: jpeg,
                        configuration: visionConfig
                    )
                } catch {
                    RTILog.log("Local vision describe failed; capture continues OCR-only: \(error)", category: "vision")
                }
            }

            guard !nonEmpty.isEmpty || visionSummary != nil else {
                throw ScreenshotError.empty
            }
            lastCapturedRegions = nonEmpty.flatMap(\.regions)
            var combined = nonEmpty.isEmpty
                ? "No machine-readable text was found on the screens."
                : formatScreenContext(nonEmpty)
            if let visionSummary {
                combined += "\n\n## What the screen looks like (local vision model)\n\(visionSummary)"
            }
            recordCaptureInSessionTrail(
                primaryText: screens.first?.text ?? "",
                visionSummary: visionSummary,
                frameJPEG: primaryJPEG,
                trigger: trigger,
                visionConfig: visionConfig
            )
            LLMController.shared.setScreenCaptureStatus(nil)
            RTILog.log(
                "Screenshot: screens=\(nonEmpty.count) context=\(combined.count) chars vision=\(visionSummary != nil).",
                category: "screenshot"
            )
            return combined
        } catch {
            LLMController.shared.setScreenCaptureStatus(errorDescription(for: error))
            throw error
        }
    }

    /// Capture only the display containing the pointer. Used by the live
    /// Visual Context Trail: no UI status is changed. The full-resolution
    /// image is released as soon as OCR (and optional JPEG encoding for the
    /// session archive) completes; only the compact JPEG travels further.
    func captureActiveDisplayFrame(includeFrame: Bool) async throws -> ActiveDisplayFrame {
        let screens = try await captureDisplaysWithOCR(activeOnly: true, includeFrame: includeFrame)
        guard let screen = screens.first else { throw ScreenshotError.noDisplay }
        let text = screen.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScreenshotError.empty }
        return ActiveDisplayFrame(text: text, frameJPEG: screen.frameJPEG)
    }

    func highlightTextOnLastCapture(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "No highlight text was provided."
        }
        guard let match = bestRegionMatch(for: trimmed) else {
            return "I couldn't find `\(trimmed)` in the most recent screen OCR. Capture the screen again if the visible content changed."
        }
        ScreenHighlightOverlay.flash(rect: match.rect)
        return "Highlighted `\(match.text)` on \(match.screenLabel)."
    }

    /// Give a manual/tool capture a home in the live session: stage the
    /// compressed frame for the archive and append a trail event carrying the
    /// vision summary. Outside a session, captures stay ephemeral as before.
    private func recordCaptureInSessionTrail(
        primaryText: String,
        visionSummary: String?,
        frameJPEG: Data?,
        trigger: String,
        visionConfig: LocalVisionConfiguration
    ) {
        guard SessionCoordinator.shared.isRunning,
              let startedAt = SessionCoordinator.shared.startedAt else { return }
        let offset = Int(Date().timeIntervalSince(startedAt))
        var frameFilename: String?
        if visionConfig.enabled, visionConfig.saveFrames, let jpeg = frameJPEG {
            let staging = VisualFrameStore.stagingDirectory(
                configHome: VaultPaths.homeDirectory(),
                startedAt: startedAt
            )
            frameFilename = try? VisualFrameStore.writeFrame(
                jpeg,
                offsetSeconds: offset,
                trigger: trigger,
                stagingDirectory: staging
            )
        }
        guard frameFilename != nil || visionSummary != nil else { return }
        VisualContextTrail.shared.recordExternalCapture(
            offsetSeconds: offset,
            text: VisualContextText.compact(primaryText),
            visionSummary: visionSummary,
            frameFilename: frameFilename
        )
    }

    private static func isScreenRecordingDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain.contains("ScreenCaptureKit") && ns.code == -3801 { return true }
        if ns.domain.contains("TCC") { return true }
        return false
    }

    private func promptForScreenRecordingAccess() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording access required"
        alert.informativeText = "RTI needs Screen Recording access to capture and read your screen. Open System Settings to grant access, then try ⌘⇧H again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func captureDisplaysWithOCR(activeOnly: Bool, includeFrame: Bool = false) async throws -> [CapturedScreenOCR] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw ScreenshotError.noDisplay
        }

        let displays = displaysWithCursorFirst(content.displays)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        var captured: [CapturedScreenOCR] = []
        let selectedDisplays = activeOnly ? Array(displays.prefix(1)) : displays
        for (index, display) in selectedDisplays.enumerated() {
            let frame = appKitFrame(for: display)
            let isPrimary = frame.contains(NSEvent.mouseLocation)
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let ocrRegions = try await OCRService.recognizeTextRegions(in: image)
            // Only the cursor display (index 0 after sorting) keeps a frame:
            // one compact JPEG bounds memory and archive size per capture.
            let frameJPEG = (includeFrame && index == 0)
                ? ScreenFrameEncoder.jpegData(from: image)
                : nil
            let label = screenLabel(index: index, total: selectedDisplays.count, isPrimary: isPrimary)
            let text = ocrRegions.map(\.text).joined(separator: "\n")
            let regions = ocrRegions.map {
                ScreenTextRegion(
                    text: $0.text,
                    rect: screenRect(for: $0.boundingBox, in: frame),
                    screenLabel: label
                )
            }
            captured.append(CapturedScreenOCR(label: label, isPrimary: isPrimary, text: text, regions: regions, frameJPEG: frameJPEG))
        }
        return captured
    }

    private func displaysWithCursorFirst(_ displays: [SCDisplay]) -> [SCDisplay] {
        let mouse = NSEvent.mouseLocation
        return displays.sorted { a, b in
            let aContains = appKitFrame(for: a).contains(mouse)
            let bContains = appKitFrame(for: b).contains(mouse)
            if aContains != bContains { return aContains }
            return a.displayID < b.displayID
        }
    }

    private func appKitFrame(for display: SCDisplay) -> CGRect {
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if screenNumber?.uint32Value == display.displayID {
                return screen.frame
            }
        }
        return CGRect(x: display.frame.origin.x, y: display.frame.origin.y, width: CGFloat(display.width), height: CGFloat(display.height))
    }

    private func screenRect(for normalizedBox: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + normalizedBox.minX * screenFrame.width,
            y: screenFrame.minY + normalizedBox.minY * screenFrame.height,
            width: normalizedBox.width * screenFrame.width,
            height: normalizedBox.height * screenFrame.height
        )
    }

    private func screenLabel(index: Int, total: Int, isPrimary: Bool) -> String {
        if total == 1 { return "Primary screen" }
        return isPrimary
            ? "Screen \(index + 1) of \(total) — cursor is here"
            : "Screen \(index + 1) of \(total) — secondary"
    }

    private func formatScreenContext(_ screens: [CapturedScreenOCR]) -> String {
        var sections: [String] = []
        for screen in screens {
            let text = truncate(screen.text, maxChars: Self.perScreenOCRChars)
            guard !text.isEmpty else { continue }
            sections.append("## \(screen.label)\n\(text)")
        }
        let body = sections.joined(separator: "\n\n")
        return "Text visible on the user's screens. The primary screen is the one containing the mouse cursor.\n\n" + truncate(body)
    }

    private func bestRegionMatch(for query: String) -> ScreenTextRegion? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }
        return lastCapturedRegions
            .map { region -> (ScreenTextRegion, Int)? in
                let haystack = normalize(region.text)
                guard !haystack.isEmpty else { return nil }
                if haystack == needle { return (region, 0) }
                if haystack.contains(needle) { return (region, 1) }
                if needle.contains(haystack), haystack.count >= 4 { return (region, 2) }
                return nil
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.text.count < rhs.0.text.count
            }
            .first?.0
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func truncate(_ text: String, maxChars: Int? = nil) -> String {
        let limit = maxChars ?? ScreenshotManager.maxOCRChars
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "\n…[truncated]"
    }

    private func errorDescription(for error: Error) -> String {
        let ns = error as NSError
        // TCC-denied screen recording typically surfaces as SCStreamError / domain com.apple.ScreenCaptureKit.
        if ns.domain.contains("ScreenCaptureKit") || ns.domain.contains("TCC") {
            return "Screen Recording permission required. Open System Settings → Privacy & Security → Screen Recording and enable RTI."
        }
        return "Screenshot failed: \(ns.localizedDescription)"
    }
}

enum ScreenshotError: Error {
    case noDisplay
    case empty
}
