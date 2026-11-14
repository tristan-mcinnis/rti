import AppKit
import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// How long a view switch takes in the real workspace window with a full
/// two-hour call loaded: transcript, a 30-turn chat, 40 note blocks and a
/// codebook. The latency hill climb (2026-11-14) runs this before and after
/// each change. Numbers always go to the log as `LATENCY …`; the budget is
/// asserted only with `RTI_TIMING_TESTS=1`.
@MainActor
final class TabSwitchLatencyTests: RenderProofTestCase {
    private let tabs: [OverlayTab] = [.assist, .transcript, .notes, .codebook, .setup]

    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
    }

    override func tearDown() async throws {
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        LLMController.shared.seedForRenderProof(entries: [])
        NotesGenerationController.shared.seedForRenderProof([])
        ResearchCodebookController.shared.seedForRenderProof(ResearchCodebook())
        LiveTabState.shared.selected = .assist
        try await super.tearDown()
    }

    private func seedTwoHourCall() {
        let entries = (0 ..< 14400).map { index in
            RenderFixtures.liveEntry(index.isMultiple(of: 3) ? "self" : "remote_1",
                                     index.isMultiple(of: 3) ? "Invented English speech segment \(index)." : "合成普通话片段，我觉得这个产品还可以 \(index)。",
                                     index * 500)
        }
        SessionCoordinator.shared.seedForRenderProof(entries: entries, interim: nil, phase: .recording,
                                                     startedAt: Date().addingTimeInterval(-7200))
        let answer = """
        - **Texture first:** the group judges body care by feel, 润但是不黏, before any claim.
        - **Patents read as proof:** 专利 makes a claim feel real, but common ingredients undercut it.
        - **Trial path:** samples and in-store trial come before a full-size purchase.

        **Suggested question for the moderator** What would make you trust the patent claim?
        """
        var chat: [ChatEntry] = []
        for index in 0 ..< 30 {
            chat.append(ChatEntry(role: "user", text: "What are the themes so far? \(index)", action: "Ask", contextUsed: true, screenContextUsed: false))
            chat.append(ChatEntry(role: "assistant", text: answer, action: "Ask", contextUsed: true, screenContextUsed: false))
        }
        LLMController.shared.seedForRenderProof(entries: chat)
        NotesGenerationController.shared.seedForRenderProof((0 ..< 40).map { index in
            GeneratedNote(timestamp: Date(), rangeStartMs: index * 180_000, rangeEndMs: (index + 1) * 180_000,
                          title: "Block \(index): patents and texture",
                          content: (0 ..< 8).map { "- Participant point \($0) about 屏障修复 (píngzhàng xiūfù, barrier repair) and price." }
                              .joined(separator: "\n"))
        })
        ResearchCodebookController.shared.seedForRenderProof(LiveRailRenderProofTests.codebook)
    }

    /// One switch: select, let SwiftUI run its transaction, lay out and draw.
    private func switchTo(_ tab: OverlayTab, in window: NSWindow) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        LiveTabState.shared.selected = tab
        RunLoop.main.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testViewSwitchLatencyWithATwoHourCall() throws {
        try measure(label: "kept")
    }

    /// The same run with every view rebuilt on each switch, as before the
    /// climb: the baseline the kept views are compared with.
    func testViewSwitchLatencyRebuildingEachView() throws {
        OverlayPanelView.keepsViews = false
        defer { OverlayPanelView.keepsViews = true }
        try measure(label: "rebuilt")
    }

    private func measure(label: String) throws {
        seedTwoHourCall()
        let model = WorkspaceModel()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WorkspaceLayout.standardSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model, callTypes: .inMemory()))
        // Off every display, like the other interaction proofs.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        _ = switchTo(.setup, in: window)

        var first: [OverlayTab: Double] = [:]
        var warm: [OverlayTab: [Double]] = [:]
        for tab in tabs {
            first[tab] = switchTo(tab, in: window)
        }
        for _ in 0 ..< 5 {
            for tab in tabs {
                warm[tab, default: []].append(switchTo(tab, in: window))
            }
        }
        var worstWarm = 0.0
        for tab in tabs {
            let median = warm[tab, default: []].sorted()[2]
            worstWarm = max(worstWarm, median)
            print(String(format: "LATENCY %@ tab=%@ first=%.1fms warm=%.1fms", label, tab.rawValue, first[tab] ?? 0, median))
        }
        print(String(format: "LATENCY %@ worst-warm=%.1fms", label, worstWarm))
        if ProcessInfo.processInfo.environment["RTI_TIMING_TESTS"] == "1" {
            XCTAssertLessThan(worstWarm, 50, "a repeat view switch should land within 50 ms")
        }
    }
}
