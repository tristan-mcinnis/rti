import CoreGraphics
import Foundation
// Vision's request types aren't Sendable yet; @preconcurrency silences the
// strict-concurrency capture warnings without changing runtime behavior.
@preconcurrency import Vision

enum OCRService {
    /// Runs Vision text recognition on `cgImage` and returns observations sorted
    /// top→bottom, left→right. Off-main; call from a background task.
    static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err { continuation.resume(throwing: err); return }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Vision origin is bottom-left; sort by -y then x for reading order.
                let sorted = observations.sorted { a, b in
                    if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.01 {
                        return a.boundingBox.origin.y > b.boundingBox.origin.y
                    }
                    return a.boundingBox.origin.x < b.boundingBox.origin.x
                }
                let text = sorted
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
