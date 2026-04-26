import Foundation
import GRDB

/// Re-runs Soniox file-mode transcription against a session's recorded WAV to
/// produce a higher-fidelity transcript than the realtime stream captured live.
/// Replaces the existing `transcript_entries` rows for the session and marks
/// `sessions.transcript_quality = "hifi"` so the UI can stop offering this
/// action once it's been used.
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

        let session: Session?
        do {
            session = try RTIDatabase.shared.pool.read { db in
                try Session.fetchOne(db, key: sessionId)
            }
        } catch {
            lastError = "Couldn't load session: \(error)"
            return
        }
        guard let session, let wavPath = session.wavPath else {
            lastError = "No audio recording on file for this session."
            return
        }
        let wavURL = URL(fileURLWithPath: wavPath)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            lastError = "Audio file no longer exists at \(wavPath)."
            return
        }

        generatingSessionId = sessionId
        lastError = nil

        currentTask = Task {
            defer { generatingSessionId = nil }
            do {
                let client = SonioxFileTranscribeClient(apiKey: apiKey)
                let transcript = try await client.transcribe(wavURL: wavURL)
                try Task.checkCancellation()
                try await Self.replaceTranscript(sessionId: sessionId, words: transcript.words)
            } catch is CancellationError {
                // intentional cancel — no error surface
            } catch {
                NSLog("[RTI] regenerate transcript failed: \(error)")
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Wipe and rewrite. Done in a single transaction so a partial failure
    /// doesn't leave the session with half the old + half the new transcript
    /// interleaved.
    nonisolated private static func replaceTranscript(sessionId: String, words: [SonioxWord]) async throws {
        let runs = collapseIntoRuns(words)
        let now = Date()
        try await RTIDatabase.shared.pool.write { db in
            try TranscriptEntry
                .filter(Column("session_id") == sessionId)
                .deleteAll(db)
            for run in runs {
                let entry = TranscriptEntry(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    speakerId: speakerLabel(run.speaker),
                    startMs: run.startMs,
                    endMs: run.endMs,
                    text: run.text,
                    confidence: run.confidence,
                    isFinal: true,
                    createdAt: now
                )
                try entry.insert(db)
            }
            try db.execute(sql: "UPDATE sessions SET transcript_quality = ? WHERE id = ?",
                           arguments: ["hifi", sessionId])
        }
    }

    private struct Run {
        let speaker: Int
        let text: String
        let startMs: Int
        let endMs: Int
        let confidence: Double
    }

    nonisolated private static func collapseIntoRuns(_ words: [SonioxWord]) -> [Run] {
        guard !words.isEmpty else { return [] }
        var groups: [[SonioxWord]] = []
        for word in words {
            if groups.last?.last?.speaker == word.speaker {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.map { group in
            let avg = group.map(\.confidence).reduce(0, +) / Double(group.count)
            return Run(
                speaker: group[0].speaker,
                text: group.map(\.text).joined(),
                startMs: group.first?.startMs ?? 0,
                endMs: group.last?.endMs ?? 0,
                confidence: avg
            )
        }
    }

    /// Speaker 0 is conventionally the local mic in our pipeline; 1+ are remote
    /// participants. Soniox async diarization only labels speakers it heard, so
    /// we trust its assignment without the realtime stream's mic-only override.
    nonisolated private static func speakerLabel(_ speaker: Int) -> String {
        speaker == 0 ? "self" : "them_\(speaker)"
    }
}
