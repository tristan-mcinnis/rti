import RTICore
import XCTest

/// The Sessions window's saved-meeting output glue: the injected generate
/// closure, the request/cancel flow, and the file-chip refresh after a save.
///
/// Uses the invented fixture vault only. The generate stub writes invented
/// data through the real store, so no provider and no network is involved.
/// (App-module types are compiled into this test bundle directly, so no
/// `@testable import` is needed.)
@MainActor
final class SessionsOutputModelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try FixtureVault.install()
    }

    /// Remove any `outputs/` folder this suite wrote into the shared fixture
    /// vault, so the render proofs never see a leftover chip.
    override func tearDown() async throws {
        if let sessions = FixtureVault.sessionsDirectory,
           let names = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) {
            for name in names {
                let outputs = sessions.appendingPathComponent(name).appendingPathComponent("outputs")
                try? FileManager.default.removeItem(at: outputs)
            }
        }
        try await super.tearDown()
    }

    private func makeModel(
        generate: (@MainActor (SessionOutputRecipe, URL, String, ChatRouteConfiguration) async throws -> SessionOutputArtifact)?,
        recipes: [SessionOutputRecipe],
        route: @escaping @MainActor () -> ChatRouteConfiguration = { sessionOutputFixtureRoute() }
    ) async throws -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            generateTitle: nil,
            persistGeneratedTitle: { _, _ in },
            now: { Date() },
            generateOutput: generate,
            outputRoute: route,
            outputRecipes: { recipes }
        ))
        await model.reload()
        return model
    }

    private func openOnboarding(_ model: SessionsWindowModel) throws {
        let row = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Onboarding") })
        model.open(row.id)
    }

    func testUnavailableWithoutTheInjectedClosures() async throws {
        let model = try await makeModel(generate: nil, recipes: [])
        XCTAssertFalse(model.isOutputAvailable)
        XCTAssertTrue(model.outputRecipes.isEmpty)
        XCTAssertNil(model.outputStatus)
    }

    func testGenerateSavesAndShowsTheOutputChip() async throws {
        let recipe = SessionOutputRecipe.builtIn(.clientFollowUp, resolve: { _ in "Write a follow-up." })
        let store = SessionOutputStore()
        let model = try await makeModel(
            generate: { recipe, directory, _, _ in
                let provenance = SessionOutputProvenance(
                    templateID: recipe.id,
                    templateName: recipe.name,
                    templateHash: recipe.templateHash,
                    sourceFile: "transcript.md",
                    sourceHash: "hash",
                    sourceBytes: 10,
                    sessionFolder: directory.lastPathComponent,
                    sessionID: nil,
                    mode: nil,
                    providerID: "stub",
                    providerName: "Stub",
                    model: "stub-1",
                    endpoint: "https://stub.invalid/v1",
                    generatedAt: "2026-06-08T16:13:05Z"
                )
                return try await store.write(
                    recipe: recipe,
                    provenance: provenance,
                    body: "Follow-up body",
                    into: directory,
                    now: Date(timeIntervalSince1970: 1_749_400_000)
                )
            },
            recipes: [recipe]
        )
        try openOnboarding(model)
        XCTAssertTrue(model.isOutputAvailable)

        model.selectOutputRecipe(id: recipe.id)
        XCTAssertEqual(model.outputFlow.phase, .ready)
        XCTAssertNil(model.outputStatus, "ready shows no status line")

        model.requestGenerateOutput()
        XCTAssertTrue(model.outputFlow.isGenerating)
        await model.runOutputGeneration()

        guard case .saved = model.outputFlow.phase else {
            return XCTFail("expected saved, got \(model.outputFlow.phase)")
        }
        XCTAssertEqual(model.outputStatus?.tone, .success)
        XCTAssertTrue(model.files.contains { $0.name.hasPrefix("output-") }, "the output appears as a file chip")
    }

    func testCancelStopsTheFlowAndDropsTheRequest() async throws {
        let recipe = SessionOutputRecipe.builtIn(.decisionLog, resolve: { _ in "Log it." })
        let model = try await makeModel(
            generate: { _, _, _, _ in throw CancellationError() },
            recipes: [recipe]
        )
        try openOnboarding(model)
        model.selectOutputRecipe(id: recipe.id)
        model.requestGenerateOutput()
        XCTAssertTrue(model.outputFlow.isGenerating)

        model.cancelOutput()
        XCTAssertEqual(model.outputFlow.phase, .cancelled)
        XCTAssertNil(model.outputRequest)
        XCTAssertEqual(model.outputStatus?.text, "Cancelled. Any output already completed remains available.")
        XCTAssertEqual(model.outputStatus?.tone, .neutral)
    }

    func testSwitchingSessionResetsTheOutputFlow() async throws {
        let recipe = SessionOutputRecipe.builtIn(.decisionLog, resolve: { _ in "Log it." })
        let model = try await makeModel(generate: { _, _, _, _ in throw SessionOutputError.emptyOutput }, recipes: [recipe])
        let onboarding = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Onboarding") })
        let pricing = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Pricing") })
        model.open(onboarding.id)
        model.selectOutputRecipe(id: recipe.id)
        model.requestGenerateOutput()
        XCTAssertTrue(model.outputFlow.isGenerating)

        model.open(pricing.id)
        XCTAssertEqual(model.outputFlow.phase, .idle)
        XCTAssertNil(model.outputFlow.selectedRecipeID)
        XCTAssertNil(model.outputRequest)
    }

    func testFailedGenerationShowsTheErrorText() async throws {
        let recipe = SessionOutputRecipe.builtIn(.researchDebrief, resolve: { _ in "Debrief." })
        let model = try await makeModel(
            generate: { _, _, _, _ in throw SessionOutputError.missingTranscript },
            recipes: [recipe]
        )
        try openOnboarding(model)
        model.selectOutputRecipe(id: recipe.id)
        model.requestGenerateOutput()
        await model.runOutputGeneration()
        XCTAssertEqual(model.outputStatus?.tone, .error)
        XCTAssertEqual(model.outputStatus?.text, SessionOutputError.missingTranscript.errorDescription)
    }

    func testMissingCredentialsAreBlockedBeforeCreatingRequest() async throws {
        let recipe = SessionOutputRecipe.builtIn(.decisionLog, resolve: { _ in "Log decisions." })
        let model = try await makeModel(generate: { _, _, _, _ in
            XCTFail("missing credentials reached transport")
            throw SessionOutputError.emptyOutput
        }, recipes: [recipe], route: {
            let provider = LLMProviderConfig(
                id: "fixture", displayName: "Fixture",
                baseURL: URL(string: "https://fixture.invalid/v1")!, model: "fixture-model",
                supportsThinking: false, apiKey: { "" }
            )
            return ChatRouteConfiguration(
                provider: provider, reasoning: .fast, imageRoute: .none, imageCount: 0,
                selection: ChatModelSelection(providerId: provider.id, reasoning: .fast)
            )
        })
        try openOnboarding(model)
        model.selectOutputRecipe(id: recipe.id)
        model.requestGenerateOutput()
        XCTAssertNil(model.outputRequest)
        XCTAssertEqual(model.outputStatus?.tone, .error)
        XCTAssertEqual(model.outputStatus?.text, ChatRouteBlocker.missingCredential(providerName: "Fixture").message)
    }

    func testGenerateFreezesDisplayedRouteBeforeItsTaskStarts() async throws {
        func route(_ model: String) -> ChatRouteConfiguration {
            let provider = LLMProviderConfig(
                id: "fixture", displayName: "Fixture",
                baseURL: URL(string: "https://fixture.invalid/v1")!,
                model: model, supportsThinking: false, apiKey: { "fixture-key" }
            )
            return ChatRouteConfiguration(
                provider: provider, reasoning: .fast, imageRoute: .none, imageCount: 0,
                selection: ChatModelSelection(providerId: provider.id, reasoning: .fast)
            )
        }
        var selected = route("first-model")
        var usedModel: String?
        let recipe = SessionOutputRecipe.builtIn(.decisionLog, resolve: { _ in "Log decisions." })
        let model = try await makeModel(generate: { _, _, _, frozen in
            usedModel = frozen.provider.model
            throw SessionOutputError.emptyOutput
        }, recipes: [recipe], route: { selected })
        try openOnboarding(model)
        model.selectOutputRecipe(id: recipe.id)
        XCTAssertTrue(model.outputProviderLabel.contains("first-model"))
        model.requestGenerateOutput()
        selected = route("second-model")
        XCTAssertTrue(model.outputProviderLabel.contains("first-model"))
        await model.runOutputGeneration()
        XCTAssertEqual(usedModel, "first-model")
    }

    func testTogglingTheChooserRefreshesCustomTemplates() async throws {
        let model = try await makeModel(generate: nil, recipes: [])
        XCTAssertFalse(model.isOutputChooserPresented)
        model.toggleOutputChooser()
        XCTAssertTrue(model.isOutputChooserPresented)
        model.toggleOutputChooser()
        XCTAssertFalse(model.isOutputChooserPresented)
    }
}

private func sessionOutputFixtureRoute() -> ChatRouteConfiguration {
    let provider = LLMProviderConfig(
        id: "fixture", displayName: "Fixture",
        baseURL: URL(string: "https://fixture.invalid/v1")!, model: "fixture-model",
        supportsThinking: false, apiKey: { "fixture-key" }
    )
    return ChatRouteConfiguration(
        provider: provider, reasoning: .fast, imageRoute: .none, imageCount: 0,
        selection: ChatModelSelection(providerId: provider.id, reasoning: .fast)
    )
}
