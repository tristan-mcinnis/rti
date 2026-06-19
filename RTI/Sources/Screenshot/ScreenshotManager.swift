import AppKit
import RTICore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private static let maxOCRChars = 12_000

    private init() {}

    /// Capture the display under the mouse cursor, OCR it, and attach the text
    /// to `LLMController` as pending screen context for the next turn.
    func captureAndAttach() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let combined = try await self.captureAndDescribe()
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
    /// `captureAndAttach()`. The image itself is never sent to the model (the
    /// provider is text-only); on-device Vision OCR extracts the text.
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
                guard !trimmed.isEmpty else {
                    LLMController.shared.setScreenAttachError("No readable text found in that image.")
                    return
                }
                RTILog.log("Dropped image: OCR=\(trimmed.count) chars.", category: "screenshot")
                LLMController.shared.attachScreenContext("Text from a dropped image:\n\(trimmed)")
            } catch {
                RTILog.log("Dropped-image OCR failed: \(error)", category: "screenshot")
                LLMController.shared.setScreenAttachError("Couldn't read text from that image.")
            }
        }
    }

    /// Capture + OCR and return the visible-text string.
    /// Throws `ScreenshotError.empty` if OCR produced no text.
    /// Used by the LLM `capture_screen` tool so the result flows directly
    /// back into the model rather than into pending-context state.
    func captureAndDescribe() async throws -> String {
        let cgImage = try await captureActiveDisplay()

        let ocrResult = try await OCRService.recognizeText(in: cgImage)
        let trimmedOCR = truncate(ocrResult)

        guard !trimmedOCR.isEmpty else {
            throw ScreenshotError.empty
        }

        RTILog.log("Screenshot: OCR=\(trimmedOCR.count) chars.", category: "screenshot")
        return "Text visible on screen:\n\(trimmedOCR)"
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

    private func captureActiveDisplay() async throws -> CGImage {
        let content = try await SCShareableContent.current
        let targetDisplay = pickActiveDisplay(from: content.displays)
        guard let display = targetDisplay else {
            throw ScreenshotError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func pickActiveDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouse) {
                let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                if let displayID, let match = displays.first(where: { $0.displayID == displayID }) {
                    return match
                }
            }
        }
        return displays.first
    }

    private func truncate(_ text: String) -> String {
        guard text.count > Self.maxOCRChars else { return text }
        let idx = text.index(text.startIndex, offsetBy: Self.maxOCRChars)
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
