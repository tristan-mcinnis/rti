import AppKit
import HouseChatCore
import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// Invented chat content and capture states at both supported window widths.
/// These proofs isolate the header and reader chrome from navigation work.
final class CompactChromeRenderProofTests: RenderProofTestCase {
    override func tearDown() async throws {
        OverlayShellModel.shared.chooser = nil
        MeetingContextStore.shared.resetAfterSession()
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    func testHeaderKeepsCaptureStateAtCompactAndStandardWidths() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        for (suffix, width) in headerWidths {
            try renderBothAppearances(
                name: "compact-chrome-header-\(suffix)",
                size: CGSize(width: width, height: House.Control.composer * 3),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: .init(phase: .idle), modes: .inMemory())
                    OverlayShellHeader(status: .init(phase: .recording), modes: .inMemory())
                    OverlayShellHeader(status: .init(phase: .paused), modes: .inMemory())
                }
                .background(House.ColorToken.surface)
            )
        }
    }

    func testExistingAssistantChoosersRenderWithTheCompactHeader() throws {
        for chooser in [OverlayShellModel.Chooser.options, .mode, .model] {
            OverlayShellModel.shared.chooser = chooser
            let name: String
            switch chooser {
            case .options: name = "options"
            case .mode: name = "mode"
            case .model: name = "model"
            }
            try renderBothAppearances(
                name: "compact-chrome-chooser-\(name)",
                size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: House.Layout.chatMinHeight),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: .init(phase: .idle), modes: .inMemory())
                    Spacer()
                }
                .overlay(alignment: .topLeading) { OverlayHeaderChooserLayer(modes: .inMemory()) }
                .background(House.ColorToken.surface)
            )
        }
    }

    func testSavedChatFooterAtCompactAndStandardReaderWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-compact-chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(
            assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")
        ))
        let conversation = try await store.thread(
            id: "compact-chrome-fixture", title: "Northwind onboarding follow-up", surface: .rtiCopilot,
            session: nil, appVersion: "proof"
        )
        let committed = try await store.appendTurn(to: conversation, turn: .init(text: "What should we check before Thursday?"))
        _ = try await store.appendTurn(to: committed.conversation, turn: .init(
            text: "Confirm the owner of the onboarding note and the date of the next review.", role: .assistant
        ))
        let turns = root.appendingPathComponent("turns")
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        try #"{"ts":"2026-09-12T07:04:00Z","action":"Assist","userInput":"What comes next?","output":"Confirm the next review.","sources":[]}"#
            .write(to: turns.appendingPathComponent("2026-09-12.jsonl"), atomically: true, encoding: .utf8)
        let library = ChatLibraryModel(location: .init(store: store, legacyTurnsRoot: turns), now: { Date() })
        await library.loadIfNeeded()
        library.select(id: conversation.id)
        await library.loadDetail()
        XCTAssertNotNil(library.detail?.record)
        for (suffix, width) in headerWidths {
            try renderBothAppearances(
                name: "compact-chrome-chat-reader-\(suffix)",
                size: CGSize(width: width - House.Layout.chatRail, height: House.Layout.chatMinHeight),
                view: ChatLibraryReader(library: library).background(House.ColorToken.surfaceRaised)
            )
        }
        library.select(logID: "2026-09-12")
        try renderBothAppearances(
            name: "compact-chrome-dated-reader",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound - House.Layout.chatRail, height: House.Layout.chatMinHeight),
            view: ChatLibraryReader(library: library).background(House.ColorToken.surfaceRaised)
        )
    }

    private var headerWidths: [(String, CGFloat)] {
        [
            ("compact", OverlayAppearanceDefaults.widthRange.lowerBound),
            ("standard", OverlayAppearanceDefaults.defaultWidth)
        ]
    }
}
