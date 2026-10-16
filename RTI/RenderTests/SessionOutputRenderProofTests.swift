import AppKit
import RTICore
import SwiftUI
import XCTest

/// Render proofs for the saved-meeting output chooser: the ready, generating,
/// saved and failed states, and the chooser inside the real Sessions window.
/// PNG prefix `session-output-`. Fixture vault only; the generate dependency
/// throws, so a proof never reaches a provider and never writes an output.
final class SessionOutputRenderProofTests: RenderProofTestCase {
    private let recipe = SessionOutputRecipe.builtIn(.clientFollowUp, resolve: { _ in "Write a follow-up." })
    private let custom = SessionOutputRecipe.custom(
        CustomOutputTemplate(id: "partner-note", name: "Partner note", instruction: "Write a partner note.")
    )
    private let savedArtifact = SessionOutputArtifact(
        url: URL(fileURLWithPath: "/tmp/outputs/client-follow-up-20260608-161305.md"),
        templateID: "client-follow-up",
        templateName: "Client follow-up draft",
        generatedAt: Date(timeIntervalSince1970: 1_749_400_000)
    )

    private func makeModel() async throws -> SessionsWindowModel {
        let model = SessionsWindowModel(dependencies: .init(
            generateTitle: nil,
            persistGeneratedTitle: { _, _ in XCTFail("a proof must never write a title") },
            now: { Date() },
            generateOutput: { _, _, _, _ in throw SessionOutputError.emptyOutput },
            outputRecipes: { [self.recipe, self.custom] }
        ))
        await model.reload()
        model.setRailVisible(false, remember: false)
        let row = try XCTUnwrap(model.rows.first { $0.title.text.hasPrefix("Onboarding") })
        model.open(row.id)
        model.isOutputChooserPresented = true
        return model
    }

    private func seeded(_ phase: SessionOutputFlow.Phase) -> SessionOutputFlow {
        var flow = SessionOutputFlow()
        flow.select(recipeID: recipe.id)
        switch phase {
        case .idle:
            flow.select(recipeID: nil)
        case .ready:
            break
        case .generating:
            flow.begin()
        case let .saved(artifact):
            flow.begin()
            flow.succeed(artifact)
        case let .failed(message):
            flow.begin()
            flow.fail(message)
        case .cancelled:
            flow.begin()
            flow.cancel()
        }
        return flow
    }

    private func render(_ name: String, _ model: SessionsWindowModel) throws {
        try renderBothAppearances(
            name: name,
            size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight),
            view: SessionsBrowserView(model: model)
        )
    }

    func testChooserReady() async throws {
        let model = try await makeModel()
        model.seedOutputFlowForRenderProof(seeded(.ready))
        try render("session-output-ready", model)
    }

    func testChooserGenerating() async throws {
        let model = try await makeModel()
        model.seedOutputFlowForRenderProof(seeded(.generating))
        try render("session-output-generating", model)
    }

    func testChooserSaved() async throws {
        let model = try await makeModel()
        model.seedOutputFlowForRenderProof(seeded(.saved(savedArtifact)))
        try render("session-output-saved", model)
    }

    func testChooserFailed() async throws {
        let model = try await makeModel()
        model.seedOutputFlowForRenderProof(seeded(.failed("The request timed out before the model answered.")))
        try render("session-output-failed", model)
    }

    /// The chooser card on its own, for a focused read of its spacing.
    func testChooserCard() async throws {
        let model = try await makeModel()
        model.seedOutputFlowForRenderProof(seeded(.ready))
        try renderBothAppearances(
            name: "session-output-card",
            size: CGSize(width: SessionsBrowserView.columnWidth, height: 380),
            view: SessionOutputsChooser(model: model)
                .padding(House.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(House.ColorToken.surface)
        )
    }
}
