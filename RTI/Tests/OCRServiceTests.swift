import XCTest
import AppKit
import CoreGraphics

/// Proves the on-device Vision OCR path actually recognises text — the same
/// `VNRecognizeTextRequest` config the live "Capture Screen" feature runs.
/// Renders known strings to a bitmap and asserts OCRService reads them back.
final class OCRServiceTests: XCTestCase {

    /// Render `text` as black-on-white at a legible size and return a CGImage.
    private func image(_ text: String, fontSize: CGFloat = 48) -> CGImage {
        let size = NSSize(width: 700, height: 140)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 24, y: 44), withAttributes: attrs)
        img.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            fatalError("could not rasterise test image")
        }
        return cg
    }

    func testRecognisesPlainSentence() async throws {
        let result = try await OCRService.recognizeText(in: image("The quick brown fox"))
        let normalized = result.lowercased()
        XCTAssertTrue(normalized.contains("quick"), "got: \(result)")
        XCTAssertTrue(normalized.contains("brown fox"), "got: \(result)")
    }

    func testRecognisesAlphanumeric() async throws {
        let result = try await OCRService.recognizeText(in: image("Order RTI-2026 total 1450"))
        XCTAssertTrue(result.contains("2026"), "got: \(result)")
        XCTAssertTrue(result.contains("1450"), "got: \(result)")
    }

    func testRecognisesMultipleLinesInReadingOrder() async throws {
        let size = NSSize(width: 500, height: 200)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40),
            .foregroundColor: NSColor.black
        ]
        "First line".draw(at: NSPoint(x: 20, y: 130), withAttributes: attrs)
        "Second line".draw(at: NSPoint(x: 20, y: 40), withAttributes: attrs)
        img.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

        let result = try await OCRService.recognizeText(in: cg)
        let first = result.range(of: "First")
        let second = result.range(of: "Second")
        XCTAssertNotNil(first, "got: \(result)")
        XCTAssertNotNil(second, "got: \(result)")
        if let f = first, let s = second {
            XCTAssertTrue(f.lowerBound < s.lowerBound, "top line should sort before bottom; got: \(result)")
        }
    }
}
