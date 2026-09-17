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

/// One manual capture's result: the OCR/vision text plus the compressed
/// screenshot itself, so the chat turn can send the image when the active
/// model takes image input.
struct ScreenCaptureResult {
    let text: String
    let imageJPEG: Data?
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
    private var attachmentTask: Task<Void, Never>?

    private init() {}

    /// Capture connected displays, OCR them, and attach the result (text plus
    /// the screenshot itself) to `LLMController` as pending context for the
    /// next turn.
    func captureAndAttach() {
        attachmentTask?.cancel()
        let requestID = LLMController.shared.beginScreenAttachment(status: "Reading all screens…")
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.captureAndDescribe(trigger: "manual", attachmentRequestID: requestID)
                try self.checkAttachmentRequest(requestID)
                LLMController.shared.attachScreenContext(result.text, image: result.imageJPEG, requestID: requestID)
            } catch is CancellationError {
                return
            } catch ScreenshotError.empty {
                LLMController.shared.setScreenAttachError("No content found on the captured screen.", requestID: requestID)
            } catch {
                guard LLMController.shared.isCurrentScreenAttachment(requestID), !Task.isCancelled else { return }
                RTILog.log("Screenshot capture failed: \(error)", category: .screenshot)
                let msg = self.errorDescription(for: error)
                LLMController.shared.setScreenAttachError(msg, requestID: requestID)
                if Self.isScreenRecordingDenied(error) {
                    self.promptForScreenRecordingAccess()
                }
            }
        }
    }

    /// Capture the frontmost window that is neither RTI's own nor on the
    /// privacy deny-list — the one the user was reading before RTI came
    /// forward — and attach its OCR text (plus a local vision description
    /// when that lane is on) as pending context for the next turn.
    func captureFocusedWindowAndAttach() {
        attachmentTask?.cancel()
        let requestID = LLMController.shared.beginScreenAttachment(status: "Reading the frontmost window…")
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.captureFocusedWindowAndDescribe(attachmentRequestID: requestID)
                try self.checkAttachmentRequest(requestID)
                LLMController.shared.attachScreenContext(result.text, image: result.imageJPEG, requestID: requestID)
            } catch is CancellationError {
                return
            } catch ScreenshotError.noFocusedWindow {
                LLMController.shared.setScreenAttachError("No other window is open to read.", requestID: requestID)
            } catch ScreenshotError.empty {
                LLMController.shared.setScreenAttachError("No content found in that window.", requestID: requestID)
            } catch {
                guard LLMController.shared.isCurrentScreenAttachment(requestID), !Task.isCancelled else { return }
                RTILog.log("Window capture failed: \(error)", category: .screenshot)
                let msg = self.errorDescription(for: error)
                LLMController.shared.setScreenAttachError(msg, requestID: requestID)
                if Self.isScreenRecordingDenied(error) {
                    self.promptForScreenRecordingAccess()
                }
            }
        }
    }

    /// Capture + OCR one window and return the text and the screenshot itself.
    /// Throws `ScreenshotError.empty` only when OCR and the image are both
    /// empty. The sibling of `captureAndDescribe()`, scoped to a single window
    /// rather than the whole display.
    ///
    /// The local vision model is deliberately NOT called here: the active
    /// model sees the screenshot itself, so a second local description only
    /// adds latency.
    func captureFocusedWindowAndDescribe(
        trigger: String = "manual.window",
        attachmentRequestID: UUID? = nil
    ) async throws -> ScreenCaptureResult {
        try checkAttachmentRequest(attachmentRequestID)
        let window = try await captureFocusedWindowWithOCR(
            includeFrame: true,
            attachmentRequestID: attachmentRequestID
        )
        try checkAttachmentRequest(attachmentRequestID)
        let text = window.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty || window.frameJPEG != nil else {
            throw ScreenshotError.empty
        }
        lastCapturedRegions = window.regions
        let combined = text.isEmpty
            ? "No machine-readable text was found in the frontmost window (\(window.label))."
            : formatWindowContext(window)
        recordCaptureInSessionTrail(
            primaryText: window.text,
            frameJPEG: window.frameJPEG,
            trigger: trigger
        )
        RTILog.log(
            "Window screenshot: \(window.label) context=\(combined.count) chars image=\(window.frameJPEG != nil).",
            category: .screenshot
        )
        return ScreenCaptureResult(text: combined, imageJPEG: window.frameJPEG)
    }

    private func formatWindowContext(_ window: CapturedScreenOCR) -> String {
        let text = truncate(window.text, maxChars: Self.perScreenOCRChars)
        return "Text visible in the frontmost window (\(window.label)).\n\n## \(window.label)\n\(text)"
    }

    /// Capture the frontmost eligible window and OCR it. The window server
    /// list (`CGWindowListCopyWindowInfo`) is ordered front-to-back, so the
    /// first window that is a normal layer, not RTI's, and not on the privacy
    /// deny-list is the one the user was looking at.
    private func captureFocusedWindowWithOCR(
        includeFrame: Bool,
        attachmentRequestID: UUID? = nil
    ) async throws -> CapturedScreenOCR {
        try checkAttachmentRequest(attachmentRequestID)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try checkAttachmentRequest(attachmentRequestID)
        guard let window = focusedWindow(in: content.windows) else {
            throw ScreenshotError.noFocusedWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // `config.width/height` are in pixels, `contentRect` is in points, and
        // the default `scalesToFit == false` only ever scales down — so a bare
        // `window.frame` would capture a 2× display at half resolution and
        // cost OCR the small text this feature exists to read.
        let pixelScale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try checkAttachmentRequest(attachmentRequestID)
        let ocrRegions = try await OCRService.recognizeTextRegions(in: image)
        try checkAttachmentRequest(attachmentRequestID)
        return CapturedScreenOCR(
            label: windowLabel(window),
            isPrimary: true,
            text: ocrRegions.map(\.text).joined(separator: "\n"),
            regions: screenRegions(ocrRegions, in: window),
            frameJPEG: includeFrame ? ScreenFrameEncoder.jpegData(from: image) : nil
        )
    }

    /// Map Vision boxes (normalized, bottom-left origin, within the window
    /// image) into AppKit global screen coordinates so the highlight tool can
    /// act on the window that was just read.
    private func screenRegions(
        _ regions: [OCRService.RecognizedTextRegion],
        in window: SCWindow
    ) -> [ScreenTextRegion] {
        let frame = appKitFrame(forWindow: window)
        let label = windowLabel(window)
        return regions.map { region in
            ScreenTextRegion(
                text: region.text,
                rect: CGRect(
                    x: frame.minX + region.boundingBox.minX * frame.width,
                    y: frame.minY + region.boundingBox.minY * frame.height,
                    width: region.boundingBox.width * frame.width,
                    height: region.boundingBox.height * frame.height
                ),
                screenLabel: label
            )
        }
    }

    /// `SCWindow.frame` is in Quartz screen coordinates (top-left origin);
    /// AppKit measures up from the primary display's bottom-left, so flip y.
    private func appKitFrame(forWindow window: SCWindow) -> CGRect {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
        return CGRect(
            x: window.frame.minX,
            y: primaryHeight - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        )
    }

    /// The topmost on-screen window that is not RTI's and not on the privacy
    /// deny-list. `windows` supplies the ScreenCaptureKit handles the capture
    /// filter needs; its order is undefined, so the front-to-back order comes
    /// from the window server instead.
    private func focusedWindow(in windows: [SCWindow]) -> SCWindow? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid != Int(ownPID) else { continue }
            let bundleId = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
            if bundleId == ownBundle || ScreenPrivacy.isExcluded(bundleIdentifier: bundleId) { continue }
            if let match = windows.first(where: { $0.windowID == CGWindowID(truncatingIfNeeded: number) }) {
                return match
            }
        }
        return nil
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Window"
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty, title != app else { return app }
        return "\(app) — \(title)"
    }

    /// OCR an image the user dropped or picked and attach the text and the
    /// image to the next turn — the drag-and-drop sibling of
    /// `captureAndAttach()`. On-device Vision OCR extracts the text; the image
    /// itself goes to the model when the provider takes image input, so the
    /// local vision model is not called here.
    func attachDroppedImage(_ image: NSImage) {
        attachmentTask?.cancel()
        let requestID = LLMController.shared.beginScreenAttachment(status: "Reading image…")
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            LLMController.shared.setScreenAttachError("Couldn't read that image.", requestID: requestID)
            return
        }
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkAttachmentRequest(requestID)
                let ocr = try await OCRService.recognizeText(in: cgImage)
                try self.checkAttachmentRequest(requestID)
                let trimmed = self.truncate(ocr)
                let jpeg = ScreenFrameEncoder.jpegData(from: cgImage)
                try self.checkAttachmentRequest(requestID)
                guard !trimmed.isEmpty || jpeg != nil else {
                    LLMController.shared.setScreenAttachError("No readable text found in that image.", requestID: requestID)
                    return
                }
                let context = trimmed.isEmpty
                    ? "A dropped image with no machine-readable text."
                    : "Text from a dropped image:\n\(trimmed)"
                RTILog.log("Dropped image: OCR=\(trimmed.count) chars image=\(jpeg != nil).", category: .screenshot)
                self.recordCaptureInSessionTrail(primaryText: trimmed, frameJPEG: jpeg, trigger: "manual.image")
                LLMController.shared.attachScreenContext(context, image: jpeg, requestID: requestID)
            } catch is CancellationError {
                return
            } catch {
                guard LLMController.shared.isCurrentScreenAttachment(requestID), !Task.isCancelled else { return }
                RTILog.log("Dropped-image OCR failed: \(error)", category: .screenshot)
                LLMController.shared.setScreenAttachError("Couldn't read text from that image.", requestID: requestID)
            }
        }
    }

    /// Capture + OCR and return the text and the screenshot itself. Throws
    /// `ScreenshotError.empty` only when OCR and the image are both empty. Used
    /// by the ⌘⇧H "Screenshot Screen" path and the LLM `capture_screen` tool.
    /// During a live session the frame is also written into the session
    /// archive so the screenshot can be found again later.
    ///
    /// The local vision model is deliberately NOT called here: the active
    /// model sees the screenshot itself, so a second local description only
    /// adds latency.
    func captureAndDescribe(trigger: String = "manual", attachmentRequestID: UUID? = nil) async throws -> ScreenCaptureResult {
        try checkAttachmentRequest(attachmentRequestID)
        // Always encode the primary frame: the chat sends the actual
        // screenshot when the model takes images, and the session keeps a copy
        // independently of whether the local vision lane is on.
        let screens = try await captureDisplaysWithOCR(
            activeOnly: false,
            includeFrame: true,
            attachmentRequestID: attachmentRequestID
        )
        try checkAttachmentRequest(attachmentRequestID)
        let nonEmpty = screens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let primaryJPEG = screens.first?.frameJPEG

        guard !nonEmpty.isEmpty || primaryJPEG != nil else {
            throw ScreenshotError.empty
        }
        lastCapturedRegions = nonEmpty.flatMap(\.regions)
        let combined = nonEmpty.isEmpty
            ? "No machine-readable text was found on the screens."
            : formatScreenContext(nonEmpty)
        recordCaptureInSessionTrail(
            primaryText: screens.first?.text ?? "",
            frameJPEG: primaryJPEG,
            trigger: trigger
        )
        RTILog.log(
            "Screenshot: screens=\(nonEmpty.count) context=\(combined.count) chars image=\(primaryJPEG != nil).",
            category: .screenshot
        )
        return ScreenCaptureResult(text: combined, imageJPEG: primaryJPEG)
    }

    private func checkAttachmentRequest(_ requestID: UUID?) throws {
        try Task.checkCancellation()
        if let requestID, !LLMController.shared.isCurrentScreenAttachment(requestID) {
            throw CancellationError()
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

    /// Give a manual capture a home in the live session: write the compressed
    /// frame into the session's staging directory so it is promoted into
    /// `<session>/frames/` when the recording ends and can be found again in
    /// the Sessions window. This is independent of the local vision lane — a
    /// screenshot the user asked for is kept. Outside a session, captures stay
    /// ephemeral as before.
    private func recordCaptureInSessionTrail(
        primaryText: String,
        frameJPEG: Data?,
        trigger: String
    ) {
        guard SessionCoordinator.shared.isRunning,
              let startedAt = SessionCoordinator.shared.startedAt else { return }
        let offset = Int(Date().timeIntervalSince(startedAt))
        var frameFilename: String?
        if let jpeg = frameJPEG {
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
        guard frameFilename != nil || !primaryText.isEmpty else { return }
        VisualContextTrail.shared.recordExternalCapture(
            offsetSeconds: offset,
            text: VisualContextText.compact(primaryText),
            visionSummary: nil,
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

    private func captureDisplaysWithOCR(
        activeOnly: Bool,
        includeFrame: Bool = false,
        attachmentRequestID: UUID? = nil
    ) async throws -> [CapturedScreenOCR] {
        try checkAttachmentRequest(attachmentRequestID)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try checkAttachmentRequest(attachmentRequestID)
        guard !content.displays.isEmpty else {
            throw ScreenshotError.noDisplay
        }

        let displays = displaysWithCursorFirst(content.displays)
        // Excluded windows are removed from the composited image itself: RTI's
        // own windows (so the overlay never OCRs itself) plus the privacy
        // deny-list (password managers, personal chat, notification banners —
        // see ScreenPrivacy). Their pixels never exist in any capture path.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedWindows = content.windows.filter {
            let bundleId = $0.owningApplication?.bundleIdentifier
            return bundleId == ownBundleIdentifier || ScreenPrivacy.isExcluded(bundleIdentifier: bundleId)
        }

        var captured: [CapturedScreenOCR] = []
        let selectedDisplays = activeOnly ? Array(displays.prefix(1)) : displays
        for (index, display) in selectedDisplays.enumerated() {
            let frame = appKitFrame(for: display)
            let isPrimary = frame.contains(NSEvent.mouseLocation)
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try checkAttachmentRequest(attachmentRequestID)
            let ocrRegions = try await OCRService.recognizeTextRegions(in: image)
            try checkAttachmentRequest(attachmentRequestID)
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
    case noFocusedWindow
    case empty
}
