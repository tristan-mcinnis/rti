import XCTest
@testable import RTICore

/// The per-turn freeze: chosen vs effective provider, model, reasoning, and
/// the image destination. Everything here is pure, so no network and no
/// credential store is involved.
final class ChatRouteConfigurationTests: XCTestCase {

    /// A key whose value can change after the route froze, so the test can
    /// prove the freeze captured it.
    private final class KeyBox: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private func provider(
        id: String = "deepseek",
        name: String = "DeepSeek",
        model: String = "deepseek-chat",
        thinking: Bool = true,
        vision: Bool = true,
        key: KeyBox = KeyBox("sk-test")
    ) -> LLMProviderConfig {
        LLMProviderConfig(
            id: id,
            displayName: name,
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: model,
            supportsThinking: thinking,
            supportsVision: vision,
            apiKey: { key.value }
        )
    }

    func testResolveUsesSelectedProviderAndModel() throws {
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek", model: "deepseek-reasoner", reasoning: .fast),
            provider: provider()
        ).get()

        XCTAssertEqual(route.provider.id, "deepseek")
        XCTAssertEqual(route.model, "deepseek-reasoner")
        XCTAssertEqual(route.selection.model, "deepseek-reasoner")
        XCTAssertFalse(route.isVisionFallback)
    }

    func testMissingKeyBlocksWithTheProviderName() {
        let result = ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "openai"),
            provider: provider(id: "openai", name: "OpenAI", key: KeyBox(""))
        )

        guard case let .failure(blocker) = result else {
            return XCTFail("an empty key must block the turn")
        }
        XCTAssertEqual(blocker, .missingCredential(providerName: "OpenAI"))
        XCTAssertTrue(blocker.message.contains("OpenAI"))
        XCTAssertTrue(blocker.message.contains("Settings"))
    }

    func testThinkingIsReportedOnlyWhenTheProviderSupportsIt() throws {
        let on = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek", reasoning: .thinking),
            provider: provider(thinking: true)
        ).get()
        XCTAssertTrue(on.smart)
        XCTAssertTrue(on.thinkingSent)

        let off = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "openai", reasoning: .thinking),
            provider: provider(id: "openai", thinking: false)
        ).get()
        XCTAssertFalse(off.smart, "a provider without the extension never claims reasoning ran")
        XCTAssertFalse(off.thinkingSent)
        XCTAssertEqual(off.reasoning, .thinking, "the user's choice is still recorded")
    }

    func testFastExplicitlyKeepsThinkingOff() throws {
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek", reasoning: .fast),
            provider: provider(thinking: true)
        ).get()
        XCTAssertFalse(route.smart)
    }

    func testImagesOnAVisionProviderGoToTheCloudAndAreLabelled() throws {
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek"),
            provider: provider(vision: true),
            imageCount: 1
        ).get()

        XCTAssertEqual(route.imageRoute, .cloudInline)
        XCTAssertTrue(route.allowsImages)
        XCTAssertEqual(route.imageCount, 1)
        XCTAssertTrue(route.imageRouteLabel.contains("cloud"))
        XCTAssertTrue(route.imageRouteLabel.contains("DeepSeek"))
    }

    func testImagesOnATextOnlyProviderDegradeToTextOnly() throws {
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "openai"),
            provider: provider(id: "openai", name: "OpenAI", vision: false),
            imageCount: 1
        ).get()

        XCTAssertEqual(route.imageRoute, .textOnly)
        XCTAssertFalse(route.allowsImages)
        XCTAssertTrue(route.imageRouteLabel.contains("stay on this Mac"))
    }

    func testRequiringCloudImagesBlocksInsteadOfSwitching() {
        let result = ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "openai", model: "gpt-text"),
            provider: provider(id: "openai", name: "OpenAI", vision: false),
            imageCount: 2,
            requireCloudImages: true
        )

        guard case let .failure(blocker) = result else {
            return XCTFail("a caller that requires cloud images must be refused, not downgraded")
        }
        XCTAssertEqual(blocker, .imagesUnsupported(providerName: "OpenAI", model: "gpt-text"))
    }

    func testVisionFallbackRunsOnlyWhenTheUserAcceptedIt() throws {
        let noFallback = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "multi", model: "text-only"),
            provider: provider(id: "multi", name: "Multi", model: "text-only", vision: false),
            options: ChatRouteOptions(visionModelIds: ["vision-model"]),
            imageCount: 1
        ).get()
        XCTAssertEqual(noFallback.imageRoute, .textOnly)
        XCTAssertFalse(noFallback.isVisionFallback)

        let accepted = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "multi", model: "text-only"),
            provider: provider(id: "multi", name: "Multi", model: "text-only", vision: false),
            options: ChatRouteOptions(
                visionModelIds: ["vision-model"],
                visionFallbackModelId: "vision-model"
            ),
            imageCount: 1
        ).get()
        XCTAssertEqual(accepted.model, "vision-model")
        XCTAssertTrue(accepted.isVisionFallback)
        XCTAssertEqual(accepted.imageRoute, .cloudInline)
        XCTAssertTrue(accepted.routeLabel.contains("vision fallback"))
        XCTAssertEqual(accepted.selection.model, "text-only", "the chosen model is still recorded")
    }

    func testTheRouteKeepsTheKeyItFrozeWith() throws {
        let box = KeyBox("sk-first")
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek"),
            provider: provider(key: box)
        ).get()

        box.value = "sk-second"
        XCTAssertEqual(route.provider.apiKey(), "sk-first", "a later key change must not alter a running turn")
    }

    func testNoImagesMeansNoImageRoute() throws {
        let route = try ChatRouteResolver.resolve(
            selection: ChatModelSelection(providerId: "deepseek"),
            provider: provider(vision: false)
        ).get()
        XCTAssertEqual(route.imageRoute, .none)
        XCTAssertEqual(route.imageRouteLabel, "")
    }
}
