import AppKit
import RTICore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

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
    }

    private struct ScreenTextRegion {
        let text: String
        let rect: CGRect
        let screenLabel: String
    }

    private var lastCapturedRegions: [ScreenTextRegion] = []

    private init() {}

    /// Capture connected displays, OCR them, and attach the text to
    /// `LLMController` as pending screen context for the next turn.
    func captureAndAttach() {
        LLMController.shared.setScreenCaptureStatus("Reading all screens…")
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
        LLMController.shared.setScreenCaptureStatus("Reading all screens…")
        do {
            let screens = try await captureAllDisplaysWithOCR()
            let nonEmpty = screens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !nonEmpty.isEmpty else {
                throw ScreenshotError.empty
            }
            lastCapturedRegions = nonEmpty.flatMap(\.regions)
            let combined = formatScreenContext(nonEmpty)
            LLMController.shared.setScreenCaptureStatus(nil)
            RTILog.log("Screenshot: screens=\(nonEmpty.count) OCR=\(combined.count) chars.", category: "screenshot")
            return combined
        } catch {
            LLMController.shared.setScreenCaptureStatus(errorDescription(for: error))
            throw error
        }
    }

    /// Capture only the display containing the pointer and return its OCR.
    /// Used by the live Visual Context Trail: no UI status is changed and the
    /// image is released as soon as on-device Vision OCR completes.
    func captureActiveDisplayDescription() async throws -> String {
        let screens = try await captureDisplaysWithOCR(activeOnly: true)
        guard let screen = screens.first else { throw ScreenshotError.noDisplay }
        let text = screen.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScreenshotError.empty }
        return text
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

    private func captureAllDisplaysWithOCR() async throws -> [CapturedScreenOCR] {
        try await captureDisplaysWithOCR(activeOnly: false)
    }

    private func captureDisplaysWithOCR(activeOnly: Bool) async throws -> [CapturedScreenOCR] {
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
            let label = screenLabel(index: index, total: selectedDisplays.count, isPrimary: isPrimary)
            let text = ocrRegions.map(\.text).joined(separator: "\n")
            let regions = ocrRegions.map {
                ScreenTextRegion(
                    text: $0.text,
                    rect: screenRect(for: $0.boundingBox, in: frame),
                    screenLabel: label
                )
            }
            captured.append(CapturedScreenOCR(label: label, isPrimary: isPrimary, text: text, regions: regions))
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
