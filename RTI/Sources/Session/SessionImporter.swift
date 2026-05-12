import AVFoundation
import Foundation
import Observation

/// Imports an external audio or video file as a fully-formed session.
/// Pipeline: transcode source → 16 kHz mono WAV in the recordings dir →
/// Soniox file-mode transcription → render markdown via `MarkdownRenderer`
/// → write through `CorpusWriter` → FTS reindex. Mirrors how live sessions
/// land on disk so imports are indistinguishable from recorded sessions.
@Observable @MainActor
final class SessionImporter {
    static let shared = SessionImporter()

    private(set) var activeFilename: String?
    private(set) var progressMessage: String?
    private(set) var lastError: String?
    /// Files still waiting after the current one. Surfaced as "Queued: N"
    /// in the banner so the user knows a batch is in flight.
    private(set) var queueCount: Int = 0
    /// Total files in the current batch (queueCount + 1 while one is active),
    /// kept for "Imported X of Y" progress text.
    private(set) var batchTotal: Int = 0
    private(set) var batchCompleted: Int = 0

    private var currentTask: Task<Void, Never>?
    private var queue: [URL] = []

    /// File extensions we accept on drop. AVFoundation handles all of these
    /// for audio extraction; anything else is rejected up front so the user
    /// gets immediate feedback instead of a deep transcode failure.
    static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "caf",
        "mp4", "mov", "m4v"
    ]

    private init() {}

    var isImporting: Bool { activeFilename != nil }

    static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        queue.removeAll()
        queueCount = 0
        batchTotal = 0
        batchCompleted = 0
        activeFilename = nil
        progressMessage = nil
    }

    func clearError() {
        lastError = nil
    }

    /// Public single-file entry point — wraps `importFiles` so existing
    /// callers keep working.
    func importFile(at sourceURL: URL) {
        importFiles([sourceURL])
    }

    /// Queue one or more URLs for transcription. Directories are walked
    /// recursively and any supported audio/video file inside is enqueued.
    /// Files are processed serially (Soniox file-mode costs money + we
    /// don't want to fan out parallel uploads).
    func importFiles(_ urls: [URL]) {
        let expanded = Self.expandSources(urls)
        guard !expanded.isEmpty else {
            lastError = "No supported audio or video files found."
            return
        }
        guard CredentialStore.soniox != nil else {
            lastError = "Soniox API key not set. Add it in Settings → Keys."
            return
        }

        // Skip files whose title already exists in the corpus or is already
        // queued — re-dropping the same recording shouldn't produce a second
        // session. Match on the filename stem (case-insensitive).
        let existingTitles = Set(
            CorpusBackedStore.allMarkdownSessions().compactMap { $0.title?.lowercased() }
        )
        let queuedTitles = Set(
            queue.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        )
        var skipped: [String] = []
        var accepted: [URL] = []
        for url in expanded {
            let title = url.deletingPathExtension().lastPathComponent
            let key = title.lowercased()
            if existingTitles.contains(key) || queuedTitles.contains(key) {
                skipped.append(title)
            } else {
                accepted.append(url)
            }
        }

        if accepted.isEmpty {
            lastError = skipped.count == 1
                ? "\"\(skipped[0])\" already exists in your sessions."
                : "All \(skipped.count) files already exist in your sessions."
            return
        }
        lastError = skipped.isEmpty ? nil :
            (skipped.count == 1
                ? "Skipped \"\(skipped[0])\" (already imported)."
                : "Skipped \(skipped.count) files already imported.")

        // If a batch is already running, append to its queue.
        let wasIdle = activeFilename == nil && queue.isEmpty
        queue.append(contentsOf: accepted)
        batchTotal += accepted.count
        queueCount = queue.count
        if wasIdle {
            batchCompleted = 0
            startNextInQueue()
        }
    }

    /// Walk a list of URLs, recursively descending into directories, and
    /// return the supported-file URLs in stable (sorted) order.
    private static func expandSources(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let next = enumerator?.nextObject() as? URL {
                    if canImport(next) { found.append(next) }
                }
                found.sort { $0.path < $1.path }
                out.append(contentsOf: found)
            } else if canImport(url) {
                out.append(url)
            }
        }
        // Dedupe while preserving order.
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    private func startNextInQueue() {
        guard !queue.isEmpty else {
            batchTotal = 0
            batchCompleted = 0
            queueCount = 0
            return
        }
        let sourceURL = queue.removeFirst()
        queueCount = queue.count
        runImport(sourceURL: sourceURL)
    }

    private func runImport(sourceURL: URL) {
        // Defensive — this is only called from startNextInQueue which
        // already validated, but check again in case of programmer error.
        guard CredentialStore.soniox != nil else { return }
        let displayTitle = sourceURL.deletingPathExtension().lastPathComponent
        let sessionId = UUID().uuidString
        activeFilename = sourceURL.lastPathComponent
        progressMessage = "Preparing…"

        let apiKey = CredentialStore.soniox ?? ""

        currentTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self else { return }
                    self.batchCompleted += 1
                    self.activeFilename = nil
                    self.progressMessage = nil
                    self.startNextInQueue()
                }
            }
            do {
                await MainActor.run { self?.progressMessage = "Extracting audio…" }
                let (wavURL, duration) = try await Self.transcodeToWAV(
                    source: sourceURL,
                    sessionId: sessionId
                )
                try Task.checkCancellation()

                await MainActor.run { self?.progressMessage = "Transcribing…" }
                let client = SonioxFileTranscribeClient(apiKey: apiKey)
                let transcript = try await client.transcribe(wavURL: wavURL)
                try Task.checkCancellation()

                await MainActor.run { self?.progressMessage = "Saving session…" }
                try await Self.writeSession(
                    sessionId: sessionId,
                    title: displayTitle,
                    wavURL: wavURL,
                    duration: duration,
                    words: transcript.words
                )
            } catch is CancellationError {
                // user cancelled — silent
            } catch {
                NSLog("[RTI] SessionImporter failed: \(error)")
                await MainActor.run {
                    self?.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    // MARK: - Transcoding

    /// Decode the source file's audio track to a 16 kHz mono Int16 WAV at
    /// the standard recordings path. Works for both pure-audio containers
    /// and video files (extracts the audio track and discards video).
    nonisolated private static func transcodeToWAV(
        source: URL,
        sessionId: String
    ) async throws -> (URL, TimeInterval) {
        let destURL = WAVWriter.defaultURL(for: sessionId)
        try? FileManager.default.removeItem(at: destURL)

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw SessionImportError.noAudioTrack }
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else { throw SessionImportError.transcodeFailed }
        reader.add(trackOutput)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { throw SessionImportError.transcodeFailed }

        let audioFile = try AVAudioFile(
            forWriting: destURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard reader.startReading() else {
            throw reader.error ?? SessionImportError.transcodeFailed
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            let frameCount = AVAudioFrameCount(length / 2) // Int16 mono
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let dest = pcm.int16ChannelData?[0] else { continue }
            pcm.frameLength = frameCount
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: dest
            )
            try audioFile.write(from: pcm)
        }

        if reader.status == .failed {
            throw reader.error ?? SessionImportError.transcodeFailed
        }
        return (destURL, duration)
    }

    // MARK: - Markdown

    nonisolated private static func writeSession(
        sessionId: String,
        title: String,
        wavURL: URL,
        duration: TimeInterval,
        words: [SonioxWord]
    ) async throws {
        let endedAt = Date()
        let startedAt = endedAt.addingTimeInterval(-max(duration, 1))
        let turns = TranscriptRender.turns(from: words)
        let inputs = MarkdownRenderer.Inputs(
            id: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            modeId: nil,
            transcriptQuality: "hifi",
            wavPath: wavURL.path,
            attendees: nil,
            speakerMap: nil,
            keyTopics: nil,
            summaryMarkdown: nil,
            notesMarkdown: nil,
            entitiesMarkdown: nil,
            turns: turns
        )
        let entry = MarkdownRenderer.make(inputs)
        let slug = CorpusWriter.slug(forTitle: title, date: startedAt)
        let corpusDir = await MainActor.run { CorpusManager.shared.corpusDirectory }
        _ = try CorpusWriter.write(entry, to: corpusDir, slug: slug)
        try? CorpusFTSReindexer.reindex(from: corpusDir, in: RTIDatabase.shared.pool)
        try? CorpusIndexer.reindex(from: corpusDir, in: RTIDatabase.shared.pool)
        await MainActor.run {
            NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
        }
    }
}

enum SessionImportError: LocalizedError {
    case noAudioTrack
    case transcodeFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:    return "This file doesn't contain an audio track."
        case .transcodeFailed: return "Couldn't decode audio from this file."
        }
    }
}
