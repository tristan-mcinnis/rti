import AppKit
import RTICore
import SwiftUI
import XCTest

/// Package D proofs: the Sessions window in the AI Chat window shape, on the
/// invented fixture vault only (`FixtureVault`; never the real vault). PNG
/// prefix `sessions-`. The model's dependencies here never reach the network
/// and never write: no content search unless a proof hands one in, no title
/// generation.
final class SessionsWindowRenderProofTests: RenderProofTestCase {
    private let windowSize = CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)

    override func tearDown() async throws {
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        // A remembered list choice must not leak into other proof classes.
        UserDefaults.standard.removeObject(forKey: SessionsWindowModel.railVisibleKey)
        try await super.tearDown()
    }

    private func makeModel(
        contentSearch: (@Sendable (String) async -> [VaultSearch.Result]?)? = nil
    ) async throws -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            contentSearch: contentSearch,
            generateTitle: nil,
            persistGeneratedTitle: { _, _ in XCTFail("a proof must never write a title") },
            now: { Date() }
        ))
        await model.reload()
        XCTAssertEqual(model.rows.count, FixtureVault.sessions.count + 1)
        return model
    }

    private func row(_ model: SessionsWindowModel, _ prefix: String) throws -> SessionsWindowModel.Row {
        try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix(prefix) }, "no row titled \(prefix)…")
    }

    private func render(_ name: String, _ model: SessionsWindowModel, size: CGSize? = nil) throws {
        try renderBothAppearances(name: name, size: size ?? windowSize, view: SessionsBrowserView(model: model))
    }

    /// Let the debounced content search land.
    private func settleSearch() async throws {
        try await Task.sleep(for: SessionsWindowRules.contentSearchDelay * 3)
    }

    // MARK: - Titles

    /// Every fixture session gets a real title: summary, manual, vault
    /// note, fallback, short test, legacy sidecar. None says "Untitled".
    func testTitlesResolveWithoutTheSummary() async throws {
        let model = try await makeModel()
        let sources = Dictionary(model.rows.map { ($0.title.text, $0.title.source) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(sources["Pricing page teardown"], .manual)
        XCTAssertEqual(sources["Onboarding Scope Review with Northwind"], .summary)
        XCTAssertEqual(sources["Fabrikam loyalty card research debrief"], .vaultNote)
        XCTAssertEqual(sources["Quarterly planning sync"], .summary)
        XCTAssertEqual(sources["Short test · 12 s"], .shortTest)
        let meeting = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Meeting · ") })
        XCTAssertTrue(meeting.title.text.hasSuffix(" · 16 min"), meeting.title.text)
        for row in model.rows {
            XCTAssertFalse(row.title.text.localizedCaseInsensitiveContains("untitled"), row.title.text)
        }
    }

    func testRowsComeOnlyFromTheFixtureVault() async throws {
        let root = try XCTUnwrap(FixtureVault.root).resolvingSymlinksInPath().path
        let model = try await makeModel()
        for row in model.rows {
            XCTAssertTrue(row.session.url.resolvingSymlinksInPath().path.hasPrefix(root), row.session.url.path)
        }
        XCTAssertEqual(model.titleMap.entries.count, FixtureVault.meetingNotes.count)
    }

    // MARK: - Window

    func testRailShown() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Onboarding").id)
        try render("sessions-rail-shown", model)
    }

    func testRailHidden() async throws {
        let model = try await makeModel()
        model.setRailVisible(false, remember: false)
        model.open(try row(model, "Onboarding").id)
        try render("sessions-rail-hidden", model)
    }

    func testLiveRow() async throws {
        let context = MeetingContextStore.shared
        let project = context.workstreamName
        defer { context.workstreamName = project }
        context.workstreamName = "Northwind app"
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: Date().addingTimeInterval(-761)
        )
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Pricing").id)
        try render("sessions-live-row", model)
    }

    func testSearchTitles() async throws {
        let model = try await makeModel(contentSearch: { _ in [] })
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.railQuery = "northwind"
        try await settleSearch()
        XCTAssertEqual(model.railRows.count, 2)
        XCTAssertEqual(model.contentSearchState, .done)
        try render("sessions-search-titles", model)
    }

    func testSearchSnippets() async throws {
        let seed = try await makeModel()
        let onboarding = try row(seed, "Onboarding")
        let note = try XCTUnwrap(seed.titleMap.entries.values.first?.fileName)
        let sessionPath = "projects/personal/rti/sessions/\(onboarding.folderName)/transcript.md"
        let results = [
            VaultSearch.Result(
                title: "Transcript", relativePath: sessionPath, modified: Date(),
                excerpt: "I'd rather ship without the tour and measure drop-off on the first screen. We can add it back in point-one.",
                score: 0
            ),
            VaultSearch.Result(
                title: "Fabrikam loyalty card research debrief", relativePath: "meetings/\(note)", modified: Date(),
                excerpt: "Most mornings, until the weekly sign-in; drop-off came after the second week of prompts.",
                score: 0
            ),
            // Outside RTI sessions and meeting notes: dropped.
            VaultSearch.Result(
                title: "Onboarding brief", relativePath: "projects/northwind/onboarding-brief.md", modified: Date(),
                excerpt: "Measure first-screen drop-off.", score: 0
            ),
        ]
        let model = try await makeModel(contentSearch: { _ in results })
        model.setRailVisible(true, remember: false)
        model.open(onboarding.id)
        model.railQuery = "drop-off"
        try await settleSearch()
        XCTAssertEqual(model.contentSearchState, .done)
        XCTAssertEqual(model.railRows.map(\.title.text), ["Onboarding Scope Review with Northwind", "Fabrikam loyalty card research debrief"])
        XCTAssertEqual(model.railRows.compactMap { model.snippet(for: $0)?.label }, ["Transcript:", "Meeting note:"])
        try render("sessions-search-snippets", model)
    }

    func testSearchUnavailable() async throws {
        let model = try await makeModel(contentSearch: { _ in nil })
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.railQuery = "sign-in"
        try await settleSearch()
        XCTAssertEqual(model.contentSearchState, .unavailable)
        try render("sessions-search-unavailable", model)
    }

    func testRowActions() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        let onboarding = try row(model, "Onboarding")
        model.open(onboarding.id)
        model.showActions(for: onboarding.id, placement: .rail)
        model.actionIndex = 1
        XCTAssertFalse(model.visibleActions.isEmpty)
        try render("sessions-row-actions", model)
    }

    func testHeaderActions() async throws {
        let model = try await makeModel()
        model.setRailVisible(false, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.showActions(placement: .header)
        try render("sessions-header-actions", model)
    }

    func testChatInThreadGrammar() async throws {
        let model = try await makeModel()
        model.setRailVisible(false, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.selectFile(named: "chat")
        guard case let .chat(turns) = model.document else {
            return XCTFail("chat.md did not parse into turns")
        }
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        try render("sessions-chat-thread", model)
    }

    func testFind() async throws {
        let model = try await makeModel()
        model.setRailVisible(false, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.selectFile(named: "transcript")
        model.showFind()
        model.findQuery = "tour"
        model.findNext()
        XCTAssertEqual(model.findStatus, "2 of 2")
        try render("sessions-find", model)
    }

    func testFallbackTitles() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Meeting · ").id)
        model.selectFile(named: "notes")
        try render("sessions-fallback-titles", model)
    }

    func testMinimumSize() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Fabrikam").id)
        model.selectFile(named: "transcript")
        try render(
            "sessions-minimum-size",
            model,
            size: CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)
        )
    }

    /// The screenshots gallery (the local-vision lane's frames). The fixture
    /// vault keeps none, so this proof draws three plain frames of its own.
    func testFramesGallery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-render-frames-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, name) in ["frame-00065-ambient-3f2a", "frame-00312-slide-9c01", "frame-00740-ambient-77be"].enumerated() {
            let size = NSSize(width: House.Layout.chatWidth / 2, height: House.Layout.chatWidth / 2 * 10 / 16)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(white: 0.25 + 0.2 * CGFloat(index), alpha: 1).setFill()
                rect.fill()
                return true
            }
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        try renderBothAppearances(
            name: "sessions-frames",
            size: CGSize(width: SessionsBrowserView.columnWidth + 2 * House.Spacing.lg, height: House.Layout.chatMinHeight),
            view: SessionFramesGallery(directory: dir)
                .padding(House.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(House.ColorToken.surface)
        )
    }

    // MARK: - Keys and layers

    /// esc pops one layer at a time and never closes the window.
    func testEscapePopsOneLayerAtATime() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        model.open(try row(model, "Onboarding").id)
        model.showFind()
        model.showActions(placement: .header)
        model.railQuery = "north"
        model.focus = .railSearch

        XCTAssertTrue(model.handle(.escape))
        XCTAssertNil(model.actionsPlacement)
        XCTAssertTrue(model.handle(.escape))
        XCTAssertFalse(model.isFindPresented)
        XCTAssertTrue(model.handle(.escape))
        XCTAssertEqual(model.railQuery, "")
        XCTAssertTrue(model.handle(.escape))
        XCTAssertFalse(model.isRailVisible)
        XCTAssertFalse(model.handle(.escape), "nothing left: the window stays")
    }

    func testCommandNumberOpensThatRow() async throws {
        let model = try await makeModel()
        let third = model.railRows[2]
        XCTAssertTrue(model.handle(.openRow(3)))
        XCTAssertEqual(model.openRowID, third.id)
        XCTAssertFalse(model.handle(.openRow(9)), "only six rows")
    }

    func testDeepLinkOpensWithTheListHidden() async throws {
        let model = try await makeModel()
        model.setRailVisible(true, remember: false)
        let fabrikam = try row(model, "Fabrikam")
        model.open(folder: fabrikam.folderName)
        XCTAssertEqual(model.openRowID, fabrikam.id)
        XCTAssertFalse(model.isRailVisible)
    }
}
