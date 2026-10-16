import Darwin
import Foundation
import RTICore

/// Owns archived source I/O. openat + O_NOFOLLOW bind every read to the opened
/// session directory and reject linked transcripts/sidecars before any upload.
actor SessionOutputSourceReader {
    struct Input: Sendable {
        let transcript: String
        let sourceBytes: Int
        let snapshot: SessionOutputSnapshot
    }

    func read(sessionDirectory: URL, folderName: String) throws -> Input {
        try Task.checkCancellation()
        let directory = open(sessionDirectory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw SessionOutputError.unsafeSource("session folder") }
        defer { close(directory) }
        guard let bytes = try readChild("transcript.md", directory: directory, limit: 8 * 1_024 * 1_024, required: true),
              let transcript = String(data: bytes, encoding: .utf8) else {
            throw SessionOutputError.missingTranscript
        }
        let metadata = try readChild("session.json", directory: directory, limit: 65_536, required: false)
            .flatMap { try? JSONDecoder().decode(SessionArchiveMetadata.self, from: $0) }
        let names = try readChild("speaker-names.json", directory: directory, limit: 65_536, required: false)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return Input(
            transcript: transcript,
            sourceBytes: bytes.count,
            snapshot: SessionOutputSnapshot(
                sessionFolder: folderName,
                sessionID: metadata?.sessionId,
                mode: metadata?.mode,
                workstream: metadata?.workstream,
                calendarTitle: metadata?.calendarTitle,
                speakerNames: SpeakerLabelMapping.displayKeyedNames(names)
            )
        )
    }

    private func readChild(_ name: String, directory: Int32, limit: Int, required: Bool) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                if required { throw SessionOutputError.missingTranscript }
                return nil
            }
            throw SessionOutputError.unsafeSource(name)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw SessionOutputError.unsafeSource(name)
        }
        guard info.st_size <= limit else { throw SessionOutputError.sourceTooLarge(name) }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= limit else { throw SessionOutputError.sourceTooLarge(name) }
        }
    }
}
