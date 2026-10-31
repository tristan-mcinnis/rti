import AppKit
import HouseChatCore
import HouseDesign
@testable import RTICore
import SwiftUI
import Vision
import XCTest

/// Real mounted composer + controller transitions, using invented sources and
/// temporary stores. No provider, recording, live history or credentials.
final class ComposerConversationBoundaryTests: RenderProofTestCase {
    private actor StreamProbe {
        private(set) var starts = 0
        func begin() { starts += 1 }
    }

    private func controller(
        store: ChatThreadStore? = nil,
        stream: LLMRequest.ToolStream? = nil,
        beforePersistence: (@Sendable () async throws -> Void)? = nil
    ) -> LLMController {
        LLMController(
            request: LLMRequest(toolStream: stream ?? { _, _, _, _, _, _ in
                XCTFail("This workflow must not call a provider")
                return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
            }),
            chatStore: store, storeIsInjected: true, sessionIDProvider: { nil },
            routeResolver: { _, _, _ in
                .success(ChatRouteConfiguration(
                    provider: LLMProviderConfig(id: "fixture", displayName: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, model: "fixture", supportsThinking: false, supportsVision: false, apiKey: { "fixture" }),
                    reasoning: .fast, imageRoute: .none, imageCount: 0,
                    selection: ChatModelSelection(providerId: "fixture", reasoning: .fast)
                ))
            },
            modeStore: .inMemory(), turnLogger: { _ in }, ambientScreenProvider: { nil },
            beforeSubmissionPersistence: beforePersistence
        )
    }

    private func host(_ controller: LLMController, queued: Bool = false) -> NSHostingView<AnyView> {
        var seed = ComposerRenderSeed(draft: "Previous draft", isQueued: queued, mentionCandidates: [])
        seed.mentionPaths = [queued ? "projects/northwind/onboarding-brief.md" : "projects/old-context-sentinel.md"]
        if !queued {
            seed.documents = [ComposerDocument(name: "old-upload-sentinel.pdf", phase: .failed("Fixture unreadable"))]
        }
        let host = NSHostingView(rootView: AnyView(
            AssistantInputView(seed: seed, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(House.Spacing.lg)
                .background(House.ColorToken.surface)
        ))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatMinHeight))
        settle(host)
        return host
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func text(in host: NSView, proof: String) throws -> String {
        settle(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: RenderProofHarness.outputDirectory.appendingPathComponent("composer-boundary-\(proof).png"))
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").lowercased()
    }

    private func datedSeed() -> ChatLibraryDatedSeed {
        let entry = ChatLibraryDatedSeed.Entry(line: 1, day: "2026-10-30", stamp: "2026-10-30T01:00:00Z", timeText: "09:00", action: "Ask", mode: nil, inSession: false, question: "Fixture question", answer: "Fixture answer", sources: [], tools: [])
        return ChatLibraryDatedSeed(id: "dated-fixture", day: "2026-10-30", scope: .entry, title: "Fixture dated entry", sourcePath: nil, entries: [entry], sourceText: "Fixture source text", prompt: "New dated conversation")
    }

    func testDatedNewChatClearsPreviousPendingSourcesAndRestoresItsPrompt() throws {
        let controller = controller()
        let host = host(controller)
        let before = try text(in: host, proof: "dated-before")
        XCTAssertTrue(before.contains("old-context-sentinel"))
        XCTAssertTrue(before.contains("old-upload-sentinel"))
        controller.applyDatedChatSeed(datedSeed())
        let after = try text(in: host, proof: "dated-after")
        XCTAssertTrue(after.contains("new dated conversation"))
        XCTAssertFalse(after.contains("old-context-sentinel"))
        XCTAssertFalse(after.contains("old-upload-sentinel"))
        XCTAssertNotNil(controller.pendingDatedSourceName)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testResumeChatClearsPreviousPendingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let saved = try await store.thread(id: "saved", title: "Saved fixture", surface: .rtiCopilot, session: nil, appVersion: "fixture")
        _ = try await store.appendTurn(to: saved, turn: .init(text: "Saved question"))
        let controller = controller(store: store)
        let host = host(controller)
        await controller.resumeChat(id: "saved")
        let after = try text(in: host, proof: "resume-after")
        XCTAssertFalse(after.contains("old-context-sentinel"))
        XCTAssertFalse(after.contains("old-upload-sentinel"))
        XCTAssertFalse(after.contains("previous draft"))
        XCTAssertEqual(controller.entries.first?.text, "Saved question")
    }

    private final class ResumeProbe: @unchecked Sendable {
        var resetRequested = false
        var newerSend: Task<Void, Never>?
    }

    func testNewChatRequestedDuringResumeWinsOverItsHistoryRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-stale-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let saved = try await store.thread(id: "saved", title: "Saved fixture", surface: .rtiCopilot, session: nil, appVersion: "fixture")
        _ = try await store.appendTurn(to: saved, turn: .init(text: "Older saved question"))
        let controller = controller(store: store)
        let probe = ResumeProbe()
        // The transition notification is synchronous and precedes the store
        // awaits, so this interleaving does not depend on filesystem timing.
        let observer = NotificationCenter.default.addObserver(forName: .rtiComposerWillSwitchConversation, object: nil, queue: nil) { note in
            guard (note.object as? LLMController) === controller else { return }
            MainActor.assumeIsolated {
                probe.resetRequested = true
                controller.newChat()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await controller.resumeChat(id: "saved")
        XCTAssertTrue(probe.resetRequested, "The later new-chat request must actually interrupt the handover")
        XCTAssertTrue(controller.entries.isEmpty, "The older resume must not replace the newly requested chat")
        XCTAssertNil(controller.lastError)
    }

    func testSupersededResumeDoesNotCancelNewSendFromTransitionObserver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-resume-reentry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let saved = try await store.thread(id: "saved", title: "Saved fixture", surface: .rtiCopilot, session: nil, appVersion: "fixture")
        _ = try await store.appendTurn(to: saved, turn: .init(text: "Older saved question"))
        let controller = controller(store: store, stream: { _, _, _, _, onContent, _ in
            onContent("Newer answer")
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        })
        let probe = ResumeProbe()
        let observer = NotificationCenter.default.addObserver(forName: .rtiComposerWillSwitchConversation, object: nil, queue: nil) { note in
            guard (note.object as? LLMController) === controller else { return }
            MainActor.assumeIsolated {
                controller.newChat()
                controller.sendAskAnything("Newer question")
                probe.newerSend = controller.activeSendForProof
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await controller.resumeChat(id: "saved")
        let send = try XCTUnwrap(probe.newerSend)
        await send.value
        XCTAssertEqual(controller.entries.map(\.text), ["Newer question", "Newer answer"])
    }

    private enum StorageFixtureFailure: Error { case unavailable }

    /// The first storage call deliberately ignores cancellation until released,
    /// like a filesystem operation already in flight. Later calls proceed.
    private actor SubmissionGate {
        private var first = true
        private var waiter: CheckedContinuation<Void, Error>?
        private var entranceWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async throws {
            guard first else { return }
            first = false
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                for entered in entranceWaiters { entered.resume() }
                entranceWaiters = []
            }
        }

        func entered() async {
            if waiter != nil { return }
            await withCheckedContinuation { entranceWaiters.append($0) }
        }

        func release(failing: Bool) {
            let pending = waiter
            waiter = nil
            if failing { pending?.resume(throwing: StorageFixtureFailure.unavailable) }
            else { pending?.resume() }
        }
    }

    func testLateFailedStorageCannotClearNewConversationStream() async throws {
        try await checkLateStorage(failing: true, newConversation: true)
    }

    func testLateSuccessfulStorageCannotClearNewConversationStream() async throws {
        try await checkLateStorage(failing: false, newConversation: true)
    }

    func testLateStorageCannotClearNewSendAfterSameConversationStop() async throws {
        try await checkLateStorage(failing: true, newConversation: false)
    }

    private func checkLateStorage(failing: Bool, newConversation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-late-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let gate = SubmissionGate()
        let probe = StreamProbe()
        let controller = controller(store: store, stream: { _, _, _, _, _, _ in
            await probe.begin()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }, beforePersistence: { try await gate.wait() })
        defer { controller.cancel() }
        controller.sendAskAnything("Obsolete question")
        let obsoleteSend = try XCTUnwrap(controller.activeSendForProof)
        await gate.entered()
        if newConversation { controller.newChat() } else { controller.cancel() }
        controller.sendAskAnything("Current question")
        // The current stream's own request is the readiness signal. This loop
        // has a bounded failure deadline; releasing obsolete storage has no race.
        let deadline = Date().addingTimeInterval(3)
        while await probe.starts == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let currentStarts = await probe.starts
        XCTAssertEqual(currentStarts, 1)
        await gate.release(failing: failing)
        await obsoleteSend.value
        XCTAssertTrue(controller.streaming, "An obsolete storage result must not stop the current stream")
        XCTAssertNil(controller.pendingDraftRestore, "An obsolete storage failure must not restore its old draft")
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.entries.contains { $0.role == "user" && $0.text == "Current question" })
    }

    func testSameConversationFailedSendRestoresDraftWithoutClearingPendingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-failed-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let controller = controller(store: store, beforePersistence: { throw StorageFixtureFailure.unavailable })
        let host = host(controller)
        controller.sendAskAnything("Restored failed question")
        let send = try XCTUnwrap(controller.activeSendForProof)
        await send.value
        XCTAssertNotNil(controller.lastError)
        let after = try text(in: host, proof: "failed-send-restored")
        XCTAssertTrue(after.contains("restored failed question"))
        XCTAssertTrue(after.contains("old-context-sentinel"))
        XCTAssertTrue(after.contains("old-upload-sentinel"))
    }

    func testNewConversationDisarmsQueuedFollowUpBeforeCancellingStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-composer-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")))
        let probe = StreamProbe()
        let controller = controller(store: store, stream: { _, _, _, _, _, _ in
            await probe.begin()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        })
        controller.sendAskAnything("Original question")
        let deadline = Date().addingTimeInterval(3)
        while await probe.starts == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let startsBefore = await probe.starts
        XCTAssertEqual(startsBefore, 1)
        let host = host(controller, queued: true)
        controller.applyDatedChatSeed(datedSeed())
        settle(host)
        try await Task.sleep(nanoseconds: 200_000_000)
        let startsAfter = await probe.starts
        XCTAssertEqual(startsAfter, 1, "Cancelling the old stream must never submit its queued draft into the new chat")
        XCTAssertTrue(controller.entries.isEmpty)
        let after = try text(in: host, proof: "queue-retired")
        XCTAssertTrue(after.contains("new dated conversation"))
        XCTAssertFalse(after.contains("onboarding-brief"))
        XCTAssertNil(controller.lastError, "A blocked accidental send must not masquerade as a cancelled queue")
    }
}
