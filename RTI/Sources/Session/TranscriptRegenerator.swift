import Foundation

/// Re-runs Soniox file-mode transcription against a session's recorded WAV
/// to produce a higher-fidelity transcript than the realtime stream
/// captured live. Replaces the transcript section of the canonical
/// markdown file in `~/meetings/` and updates `transcript_quality: hifi`
/// in its frontmatter.
@MainActor
final class TranscriptRegenerator: ObservableObject {
    static let shared = TranscriptRegenerator()

    @Published private(set) var generatingSessionId: String?
    @Published private(set) var lastError: String?

    private var currentTask: Task<Void, Never>?

    private init() {}

    var isGenerating: Bool { generatingSessionId != nil }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        generatingSessionId = nil
    }

    func regenerate(sessionId: String) {
        guard generatingSessionId == nil else { return }
        guard let apiKey = CredentialStore.soniox else {
            lastError = "Soniox API key not set. Add it in Settings → Keys."
            return
        }
        guard let url = CorpusBackedStore.markdownURL(forSessionId: sessionId),
              let entry = try? CorpusReader.read(url) else {
            lastError = "No markdown file on disk for this session."
            return
        }
        guard let wavPath = entry.frontmatter.wavPath else {
            lastError = "No audio recording on file for this session."
            return
        }
        let wavURL = URL(fileURLWithPath: (wavPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            lastError = "Audio file no longer exists at \(wavPath)."
            return
        }

        generatingSessionId = sessionId
        lastError = nil
        let fileURL = url
        let baseEntry = entry

        currentTask = Task { [weak self] in
            defer { Task { @MainActor in self?.generatingSessionId = nil } }
            do {
                let client = SonioxFileTranscribeClient(apiKey: apiKey)
                let transcript = try await client.transcribe(wavURL: wavURL)
                try Task.checkCancellation()
                try Self.replaceTranscript(in: fileURL, baseEntry: baseEntry, words: transcript.words)
                // Reindex FTS so the upgraded transcript is searchable.
                if let dir = await MainActor.run(body: { CorpusManager.shared.corpusDirectory }) as URL? {
                    try? CorpusFTSReindexer.reindex(from: dir, in: RTIDatabase.shared.pool)
                    try? CorpusIndexer.reindex(from: dir, in: RTIDatabase.shared.pool)
                }
            } catch is CancellationError {
                // intentional cancel — no error surface
            } catch {
                NSLog("[RTI] regenerate transcript failed: \(error)")
                await MainActor.run {
                    self?.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    /// Re-renders the markdown body's `## Transcript` section with the new
    /// hi-fi turns; flips `transcript_quality: hifi` in frontmatter so the
    /// UI can stop offering regenerate. Atomic via `CorpusWriter`'s tmp+
    /// rename pattern (here we write directly because we already know the
    /// destination path and want to overwrite).
    nonisolated private static func replaceTranscript(
        in url: URL,
        baseEntry: CorpusEntry,
        words: [SonioxWord]
    ) throws {
        let turns = TranscriptRender.turns(from: words)
        let renderedTranscript = TranscriptRender.render(turns: turns)
        // Replace everything from `## Transcript` onward in the body.
        var body = baseEntry.body
        let marker = "## Transcript"
        if let r = body.range(of: marker) {
            body = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { body += "\n\n" }
            body += "## Transcript\n" + renderedTranscript
        } else {
            body += (body.hasSuffix("\n") ? "" : "\n") + "\n## Transcript\n" + renderedTranscript
        }

        var fm = baseEntry.frontmatter
        fm.transcriptQuality = "hifi"
        let updated = CorpusEntry(frontmatter: fm, body: body)
        let rendered = try updated.render()
        let tmp = url.deletingPathExtension().appendingPathExtension("md.tmp")
        try rendered.write(to: tmp, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
