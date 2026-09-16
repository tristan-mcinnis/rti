import AVFoundation
import Foundation
import Observation
import RTICore

/// Native audio I/O stays on its actor. Every discovered leg must load before
/// playback is offered; an unreadable leg fails visibly rather than disappearing.
actor SessionAudioPlayback {
    struct Snapshot: Sendable {
        var duration: TimeInterval = 0
        var position: TimeInterval = 0
        var isPlaying = false
        var sources = ""
    }
    enum Action: Sendable { case play, pause, seek(TimeInterval) }
    private var generation: UUID?
    private var players: [AVAudioPlayer] = []
    private var legs: [SessionAudioTimeline.Leg] = []
    private var state = Snapshot()
    private var startedAt: TimeInterval?
    private var startingPosition: TimeInterval = 0

    func load(_ directory: URL?, generation: UUID) throws -> Snapshot {
        stopPlayers()
        self.generation = generation
        players = []
        legs = []
        state = Snapshot()
        guard let directory else { return state }
        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: directory)
        guard !inputs.isEmpty else { throw PlaybackError.unavailable }
        do {
            for input in inputs {
                let player = try AVAudioPlayer(contentsOf: input.url)
                guard player.prepareToPlay() else { throw PlaybackError.unreadable }
                players.append(player)
                legs.append(.init(offset: Double(input.offsetMs) / 1_000, duration: player.duration))
            }
        } catch {
            stopPlayers()
            players = []
            throw PlaybackError.unreadable
        }
        state.duration = SessionAudioTimeline.duration(of: legs)
        let hasMic = inputs.contains { $0.defaultSpeaker != "Remote speaker" }
        let hasSystem = inputs.contains { $0.defaultSpeaker == "Remote speaker" }
        state.sources = hasMic && hasSystem ? "Microphone + system audio" : (hasMic ? "Microphone only" : "System audio only")
        return state
    }

    func update(_ action: Action?, generation: UUID) throws -> Snapshot {
        guard self.generation == generation else { return Snapshot() }
        updatePosition()
        if let action {
            switch action {
            case .play:
                if state.position >= state.duration { state.position = 0 }
                try play()
            case .pause:
                stopPlayers()
            case let .seek(position):
                let resume = state.isPlaying
                stopPlayers()
                state.position = min(max(0, position), state.duration)
                if resume { try play() }
            }
        }
        return state
    }

    func stop(generation: UUID) {
        guard self.generation == generation else { return }
        updatePosition()
        stopPlayers()
    }

    private func play() throws {
        guard let first = players.first, state.duration > 0 else { return }
        // All players schedule against the same hardware clock. A delayed
        // system leg stays delayed when seeking before its first sample.
        let lead: TimeInterval = 0.05
        let deviceStart = first.deviceCurrentTime + lead
        for start in SessionAudioTimeline.starts(at: state.position, legs: legs) {
            let player = players[start.index]
            player.currentTime = start.sourceTime
            guard player.play(atTime: deviceStart + start.delay) else {
                stopPlayers()
                throw PlaybackError.unreadable
            }
        }
        startingPosition = state.position
        startedAt = ProcessInfo.processInfo.systemUptime + lead
        state.isPlaying = true
    }

    private func updatePosition() {
        guard state.isPlaying, let startedAt else { return }
        state.position = min(state.duration, startingPosition + max(0, ProcessInfo.processInfo.systemUptime - startedAt))
        if state.position >= state.duration { stopPlayers() }
    }
    private func stopPlayers() {
        players.forEach { $0.stop() }
        state.isPlaying = false
        startedAt = nil
    }
    enum PlaybackError: LocalizedError {
        case unavailable, unreadable
        var errorDescription: String? {
            switch self {
            case .unavailable: "No playable recording was retained for this session."
            case .unreadable: "The recording could not be opened. Reveal the session in Finder to inspect its audio files."
            }
        }
    }
}

/// The SwiftUI task owns polling and cancellation. Hiding the window or opening
/// another session stops the old generation without stopping a newly opened one.
@MainActor
@Observable
final class SessionPlaybackModel {
    private(set) var duration: TimeInterval = 0
    private(set) var position: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var sources = ""
    private(set) var error: String?
    @ObservationIgnored private let player = SessionAudioPlayback()
    @ObservationIgnored private var pendingAction: SessionAudioPlayback.Action?
    @ObservationIgnored private var activeGeneration: UUID?
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?

    func toggle() {
        if case .play? = pendingAction { pendingAction = .pause }
        else if case .pause? = pendingAction { pendingAction = .play }
        else { pendingAction = isPlaying ? .pause : .play }
        wake?.yield(())
    }
    func seek(to position: TimeInterval) { pendingAction = .seek(position); wake?.yield(()) }
    func pause() { pendingAction = .pause; wake?.yield(()) }

    func run(directory: URL?) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        activeGeneration = generation
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = signal.continuation
        var events = signal.stream.makeAsyncIterator()
        defer {
            signal.continuation.finish()
            if activeGeneration == generation { wake = nil }
        }
        pendingAction = nil
        isLoading = directory != nil
        error = nil
        do {
            let initial = try await player.load(directory, generation: generation)
            guard !Task.isCancelled, activeGeneration == generation else {
                await player.stop(generation: generation)
                return
            }
            apply(initial)
            isLoading = false
            guard directory != nil else { return }
            while !Task.isCancelled {
                // Paused playback sleeps until a control is used. No idle
                // timer or repeated SwiftUI redraws while reading a session.
                if !isPlaying, pendingAction == nil {
                    guard await events.next() != nil else { break }
                }
                let action = pendingAction
                pendingAction = nil
                let snapshot = try await player.update(action, generation: generation)
                guard activeGeneration == generation else { break }
                apply(snapshot)
                if isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            }
        } catch is CancellationError {
            // View/window/session lifetime ended.
        } catch {
            if activeGeneration == generation { self.error = error.localizedDescription }
        }
        await player.stop(generation: generation)
        if activeGeneration == generation {
            isPlaying = false
            isLoading = false
        }
    }
    private func apply(_ state: SessionAudioPlayback.Snapshot) {
        duration = state.duration
        position = state.position
        isPlaying = state.isPlaying
        sources = state.sources
    }
}
