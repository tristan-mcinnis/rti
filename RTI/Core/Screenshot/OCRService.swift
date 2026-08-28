import CoreGraphics
import Foundation
// Vision's request types aren't Sendable yet; @preconcurrency silences the
// strict-concurrency capture warnings without changing runtime behavior.
@preconcurrency import Vision

public enum OCRServiceError: Error, LocalizedError {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "OCR timed out after 30 seconds."
        }
    }
}

public enum OCRService {
    public static let usesLanguageCorrection = false

    public struct RecognizedTextRegion: Sendable, Equatable {
        public let text: String
        public let boundingBox: CGRect

        public init(text: String, boundingBox: CGRect) {
            self.text = text
            self.boundingBox = boundingBox
        }
    }

    /// Runs Vision text recognition on `cgImage` and returns observations sorted
    /// top→bottom, left→right. Races the Vision request against a 30-second
    /// timeout so a hung Vision completion handler doesn't stall the caller
    /// indefinitely. Off-main; call from a background task.
    public static func recognizeText(in cgImage: CGImage) async throws -> String {
        let regions = try await recognizeTextRegions(in: cgImage)
        return regions.map(\.text).joined(separator: "\n")
    }

    public static func recognizeTextRegions(in cgImage: CGImage) async throws -> [RecognizedTextRegion] {
        try await withThrowingTaskGroup(of: [RecognizedTextRegion].self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw OCRServiceError.timedOut
            }
            group.addTask {
                try await _recognizeTextRegions(in: cgImage)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func _recognizeTextRegions(in cgImage: CGImage) async throws -> [RecognizedTextRegion] {
        try await withCheckedThrowingContinuation { continuation in
            // The Vision callback and the dispatched perform() may race; this
            // flag is set once by whichever finishes first. Class storage so
            // Swift's concurrency checker can see the mutation is shared.
            let resumed = ResumedFlag()
            let request = VNRecognizeTextRequest { req, err in
                guard resumed.tryMark() else { return }
                if let err { continuation.resume(throwing: err); return }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Vision origin is bottom-left; sort by -y then x for reading order.
                let sorted = observations.sorted { a, b in
                    if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.01 {
                        return a.boundingBox.origin.y > b.boundingBox.origin.y
                    }
                    return a.boundingBox.origin.x < b.boundingBox.origin.x
                }
                let regions = sorted.compactMap { observation -> RecognizedTextRegion? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return RecognizedTextRegion(text: text, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: regions)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    if resumed.tryMark() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// Atomically-set one-shot flag. Used by `_recognizeText` to guarantee the
/// continuation resumes exactly once across the Vision-callback / perform-
/// error race.
private final class ResumedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true on the first call, false on every subsequent call.
    func tryMark() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
