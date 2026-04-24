import AVFoundation
import Combine
import Foundation
import GRDB

struct LiveEntry: Identifiable {
    let id = UUID()
    let speakerId: String
    let text: String
    let startMs: Int
    let confidence: Double
}

@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var currentSessionId: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var liveEntries: [LiveEntry] = []
    @Published private(set) var interimLine: String?
    @Published private(set) var lastError: String?

    private let audio = AudioCaptureManager()
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var lastFinalizedEndMs: Int = 0

    private init() {}

    func toggleSession() {
        if isRunning {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        guard !isRunning else { return }
        lastError = nil

        audio.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.lastError = "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
                return
            }
            self.launchSession()
        }
    }

    private func launchSession() {
        let sessionId = UUID().uuidString
        let now = Date()
        let wavURL = WAVWriter.defaultURL(for: sessionId)

        do {
            try RTIDatabase.shared.pool.write { db in
                let session = Session(id: sessionId, startedAt: now, endedAt: nil, wavPath: wavURL.path, notes: nil)
                try session.insert(db)
            }
        } catch {
            lastError = "DB insert failed: \(error)"
            return
        }

        do {
            try wav.open(at: wavURL)
        } catch {
            NSLog("[RTI] WAV open failed: \(error)")
        }

        let client = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
        client.onWords = { [weak self] words in self?.handleWords(words) }
        client.connect()
        self.soniox = client

        audio.onPCMBuffer = { [weak self] buffer in self?.handleAudioBuffer(buffer) }
        do {
            try audio.start()
        } catch {
            lastError = "Audio start failed: \(error)"
            teardownOnFailure()
            return
        }

        currentSessionId = sessionId
        startedAt = now
        liveEntries = []
        interimLine = nil
        lastFinalizedEndMs = 0
        isRunning = true
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        audio.stop()
        soniox?.finalize()
        isRunning = false

        let endedAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.completeStop(sessionId: sessionId, endedAt: endedAt)
        }
    }

    private func completeStop(sessionId: String, endedAt: Date) {
        guard currentSessionId == sessionId else { return }

        soniox?.disconnect()
        soniox = nil
        wav.close()

        do {
            try RTIDatabase.shared.pool.write { db in
                if var session = try Session.fetchOne(db, key: sessionId) {
                    session.endedAt = endedAt
                    try session.update(db)
                }
            }
        } catch {
            NSLog("[RTI] session update failed: \(error)")
        }

        currentSessionId = nil
        startedAt = nil
        interimLine = nil
    }

    private func teardownOnFailure() {
        audio.stop()
        soniox?.disconnect()
        soniox = nil
        wav.close()
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        wav.append(buffer)

        guard let int16 = buffer.int16ChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let byteCount = frameLength * MemoryLayout<Int16>.size
        let data = Data(bytes: int16[0], count: byteCount)
        soniox?.sendAudio(data)
    }

    private func handleWords(_ words: [SonioxWord]) {
        guard let sessionId = currentSessionId else { return }

        let finals = words.filter { $0.isFinal && $0.endMs > lastFinalizedEndMs }
        let interims = words.filter { !$0.isFinal }

        if !finals.isEmpty {
            let runs = groupByRuns(finals)
            let now = Date()
            do {
                try RTIDatabase.shared.pool.write { db in
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
                }
            } catch {
                NSLog("[RTI] transcript insert failed: \(error)")
            }

            for run in runs {
                liveEntries.append(LiveEntry(
                    speakerId: speakerLabel(run.speaker),
                    text: run.text,
                    startMs: run.startMs,
                    confidence: run.confidence
                ))
            }
            lastFinalizedEndMs = max(lastFinalizedEndMs, finals.map(\.endMs).max() ?? lastFinalizedEndMs)
        }

        if interims.isEmpty {
            interimLine = nil
        } else {
            let runs = groupByRuns(interims)
            interimLine = runs.map { "\(speakerLabel($0.speaker)): \($0.text)" }.joined(separator: "  ")
        }
    }

    private struct Run {
        let speaker: Int
        let text: String
        let startMs: Int
        let endMs: Int
        let confidence: Double
    }

    private func groupByRuns(_ words: [SonioxWord]) -> [Run] {
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
            let confidenceAvg = group.map(\.confidence).reduce(0, +) / Double(group.count)
            return Run(
                speaker: group[0].speaker,
                text: group.map(\.text).joined(),
                startMs: group.first?.startMs ?? 0,
                endMs: group.last?.endMs ?? 0,
                confidence: confidenceAvg
            )
        }
    }

    private func speakerLabel(_ speaker: Int) -> String {
        // POC-2 is mic-only: everything captured is the user. When system-audio loopback lands
        // in a later POC, it will run a second audio stream with a different speaker mapping.
        "self"
    }
}
