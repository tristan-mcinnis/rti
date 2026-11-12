import Darwin
import Foundation

/// Append confirmed provider tokens as received. Interim hypotheses belong to
/// the live display. Each leg's provider clock starts again on a new stream.
public final class SonioxLiveJournal {
    public static let filename = "soniox-live.jsonl"

    public struct Batch: Codable, Sendable {
        public let leg: String
        public let stream: String
        public let baseMs: Int
        public let tokens: [SonioxWord]
    }

    private let file: FileHandle
    private let queue = DispatchQueue(label: "rti.soniox.raw", qos: .utility)
    private let onFailure: @Sendable (String) -> Void

    public init(directory: URL, onFailure: @escaping @Sendable (String) -> Void) throws {
        let path = directory.appendingPathComponent(Self.filename).path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.onFailure = onFailure
    }

    public func append(_ words: [SonioxWord], leg: String, stream: String, baseMs: Int) {
        let tokens = words.filter(\.isFinal)
        guard !tokens.isEmpty else { return }
        let batch = Batch(leg: leg, stream: stream, baseMs: baseMs, tokens: tokens)
        queue.async { [file, onFailure] in
            do {
                var data = try JSONEncoder().encode(batch)
                data.append(0x0A)
                try file.write(contentsOf: data)
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }

    /// Receipt and close are serialized by SessionCoordinator. Drain the file
    /// queue before the session finalizer publishes its archive references.
    public func close() throws {
        try queue.sync {
            defer { try? file.close() }
            try file.synchronize()
        }
    }
}
