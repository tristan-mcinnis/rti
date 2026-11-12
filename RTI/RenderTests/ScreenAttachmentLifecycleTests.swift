import AppKit
import XCTest

/// Invented text and an in-memory image only. Never captures a display,
/// reads a user file, or calls OCR/vision/chat providers.
final class ScreenAttachmentLifecycleTests: RenderProofTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LLMController.shared.seedForRenderProof(entries: [])
        LLMController.shared.clearPendingScreenContext()
    }

    override func tearDown() async throws {
        LLMController.shared.clearPendingScreenContext()
        try await super.tearDown()
    }

    func testReplacementShowsReadingAndDropsPreviousTextImmediately() {
        let llm = LLMController.shared
        llm.attachScreenContext("Previous invented image")
        let requestID = llm.beginScreenAttachment(status: "Reading image…")

        XCTAssertNil(llm.pendingScreenContext)
        XCTAssertEqual(llm.screenCaptureStatus, "Reading image…")
        XCTAssertTrue(llm.isCurrentScreenAttachment(requestID))
    }

    func testRemovedAttachmentRejectsLateSuccessStatusAndError() {
        let llm = LLMController.shared
        let requestID = llm.beginScreenAttachment(status: "Reading image…")
        llm.clearPendingScreenContext()

        llm.attachScreenContext("Late invented OCR", requestID: requestID)
        llm.setScreenAttachError("Late invented failure", requestID: requestID)

        XCTAssertNil(llm.pendingScreenContext)
        XCTAssertNil(llm.screenCaptureStatus)
        XCTAssertNil(llm.lastError)
    }

    func testOlderRequestCannotReplaceNewerReadingOrCompletedAttachment() {
        let llm = LLMController.shared
        let oldID = llm.beginScreenAttachment(status: "Reading all screens…")
        let newID = llm.beginScreenAttachment(status: "Reading image…")

        llm.setScreenAttachError("Old capture failure", requestID: oldID)
        llm.attachScreenContext("Old invented OCR", requestID: oldID)
        XCTAssertEqual(llm.screenCaptureStatus, "Reading image…")
        XCTAssertNil(llm.pendingScreenContext)
        XCTAssertNil(llm.lastError)

        llm.attachScreenContext("New invented OCR", requestID: newID)
        llm.attachScreenContext("Old invented OCR", requestID: oldID)
        llm.setScreenAttachError("Old capture failure", requestID: oldID)
        XCTAssertEqual(llm.pendingScreenContext, "New invented OCR")
        XCTAssertNil(llm.screenCaptureStatus)
        XCTAssertNil(llm.lastError)
    }

    func testCurrentFailureClearsOldTextAndRetryClearsError() {
        let llm = LLMController.shared
        llm.attachScreenContext("Previous invented OCR")
        let requestID = llm.beginScreenAttachment(status: "Reading image…")
        llm.setScreenAttachError("No readable text found in that image.", requestID: requestID)
        XCTAssertNil(llm.pendingScreenContext)
        XCTAssertEqual(llm.screenCaptureStatus, "No readable text found in that image.")
        XCTAssertEqual(llm.lastError, llm.screenCaptureStatus)

        _ = llm.beginScreenAttachment(status: "Reading image…")
        XCTAssertNil(llm.lastError)
        XCTAssertEqual(llm.screenCaptureStatus, "Reading image…")
    }

    func testClearingChatInvalidatesPendingReader() {
        let llm = LLMController.shared
        let requestID = llm.beginScreenAttachment(status: "Reading image…")
        llm.resetMemory()
        llm.attachScreenContext("Late invented OCR", requestID: requestID)
        XCTAssertNil(llm.pendingScreenContext)
        XCTAssertNil(llm.screenCaptureStatus)
    }

    func testDroppedImageHasIndependentDocumentProvenance() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32
        ))
        let bytes = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let attachment = try await ExternalDocumentLoader.load(imageData: bytes)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(ChatSourcePayload(from: attachment).archiveKind, .image)
        XCTAssertNotNil(attachment.normalizedImage)
        XCTAssertNil(LLMController.shared.pendingScreenContext)
    }
}
