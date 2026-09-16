import AppKit
import AVFoundation
import RTICore
import SwiftUI
import XCTest

private actor SessionTrashProbe {
    private(set) var directories: [URL] = []
    func record(_ directory: URL) { directories.append(directory) }
}

/// Invented fixture vault only. No OS sharing, clipboard writes, actual Trash
/// moves, recording, network calls, or audio playback happen in these proofs.
final class SessionPlaybackActionProofTests: RenderProofTestCase {
    private func model(trash: (@Sendable (URL) async throws -> Void)? = { _ in }) async -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            contentSearch: nil, generateTitle: nil, persistGeneratedTitle: { _, _ in },
            now: { Date() }, trashSession: trash, shareText: { _ in }
        ))
        await model.reload()
        return model
    }

    func testRoundedSessionsAndDiscoverableActionsAtStandardAndMinimumSizes() async throws {
        let model = await model()
        let row = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Onboarding") })
        model.open(row.id)
        model.selectFile(named: "summary")
        model.setRailVisible(true, remember: false)
        try renderBothAppearances(name: "sessions-polish-summary", size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight), view: SessionsBrowserView(model: model))
        try renderBothAppearances(name: "sessions-polish-minimum", size: CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight), view: SessionsBrowserView(model: model))
        model.selectFile(named: "chat")
        try renderBothAppearances(name: "sessions-polish-saved-chat", size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight), view: SessionsBrowserView(model: model))
        model.showActions(placement: .header)
        model.actionQuery = "trsh"
        XCTAssertEqual(model.visibleActions, [.trash])
        try renderBothAppearances(name: "sessions-polish-actions-search", size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight), view: SessionsBrowserView(model: model))
    }

    func testTrashRequiresConfirmationAndNeverOffersLegacyMeetingDeletion() async throws {
        let probe = SessionTrashProbe()
        let model = await model(trash: { await probe.record($0) })
        let row = try XCTUnwrap(model.rows.first { $0.session.isRTIArchive })
        let legacy = try XCTUnwrap(model.rows.first { !$0.session.isRTIArchive })
        XCTAssertFalse(model.actions(for: legacy).contains(.trash))
        model.perform(.trash, rowID: row.id)
        XCTAssertTrue(model.isDeleteConfirmationPresented)
        await model.deleteConfirmedSession()
        let before = await probe.directories
        XCTAssertTrue(before.isEmpty, "opening the confirmation must not remove anything")
        model.cancelDeletion()
        XCTAssertNil(model.pendingDeletionRowID)
        model.perform(.trash, rowID: row.id)
        model.confirmDeletion()
        await model.deleteConfirmedSession()
        let after = await probe.directories
        XCTAssertEqual(after, [row.session.url])
        XCTAssertFalse(model.isDeleting)
    }

    func testPlaybackLoadsBothLegsAndRejectsAnUnreadableOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rti-audio-proof-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSilentWAV(directory.appendingPathComponent("audio-mic.wav"))
        try writeSilentWAV(directory.appendingPathComponent("audio-system.wav"))
        try Data(#"{"systemAudioStartOffsetMs":2000}"#.utf8).write(to: directory.appendingPathComponent("session.json"))
        let player = SessionAudioPlayback()
        let generation = UUID()
        let loaded = try await player.load(directory, generation: generation)
        XCTAssertEqual(loaded.sources, "Microphone + system audio")
        XCTAssertEqual(loaded.duration, 3, accuracy: 0.01)
        let sought = try await player.update(.seek(2.5), generation: generation)
        XCTAssertEqual(sought.position, 2.5, accuracy: 0.01)
        XCTAssertFalse(sought.isPlaying)
        try Data(repeating: 0x41, count: 128).write(to: directory.appendingPathComponent("audio-system.wav"))
        do {
            _ = try await player.load(directory, generation: UUID())
            XCTFail("an unreadable system leg must not silently become microphone-only playback")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be opened"))
        }
    }

    func testPlaybackCardUsesOnlySyntheticAudioAndNeverAutoplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rti-playback-card-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSilentWAV(directory.appendingPathComponent("audio-mic.wav"))
        let playback = SessionPlaybackModel()
        let lifetime = Task { await playback.run(directory: directory) }
        defer { lifetime.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while playback.duration == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(playback.duration, 0)
        XCTAssertFalse(playback.isPlaying)
        try renderBothAppearances(name: "sessions-playback-card", size: CGSize(width: House.Layout.answerMaxWidth, height: House.Control.input + House.Spacing.xl), view: SessionPlaybackBar(playback: playback).padding(House.Spacing.xs).background(House.ColorToken.surface))
    }

    private func writeSilentWAV(_ url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData?.pointee.initialize(repeating: 0, count: 8_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
