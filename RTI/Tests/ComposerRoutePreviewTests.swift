import XCTest
@testable import RTICore

/// The route the composer names before Send: the chosen provider, model and
/// reasoning, where a pending image would go, and the reason a blocked turn
/// cannot run. Everything is pure, so no network and no credential store.
final class ComposerRoutePreviewTests: XCTestCase {

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

    func testTheChosenLabelIsTheOneTheAppAlreadyShows() {
        let preview = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "deepseek", reasoning: .thinking),
            provider: provider(),
            imageCount: 0,
            chosenLabel: "DeepSeek · deepseek-chat · Thinking"
        )
        XCTAssertEqual(preview.label, "DeepSeek · deepseek-chat · Thinking")
        XCTAssertEqual(preview.barLabel, preview.label)
        XCTAssertEqual(preview.imageRouteLabel, "", "no image, no destination claim")
        XCTAssertFalse(preview.isBlocked)
        XCTAssertFalse(preview.usesVisionFallback)
        XCTAssertNil(preview.blockerLabel)
    }

    func testAPendingImageNamesWhereItGoes() {
        let preview = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "deepseek"),
            provider: provider(),
            imageCount: 1,
            chosenLabel: "DeepSeek · deepseek-chat · Fast"
        )
        XCTAssertFalse(preview.isBlocked)
        XCTAssertTrue(preview.imageRouteLabel.contains("cloud"))
        XCTAssertTrue(preview.imageRouteLabel.contains("DeepSeek"))
    }

    func testATextOnlyRouteKeepsTheImageOnThisMacAndSaysSo() {
        let preview = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "local"),
            provider: provider(id: "local", name: "Local Models", vision: false),
            imageCount: 1,
            chosenLabel: "Local Models · local-chat · Fast"
        )
        XCTAssertFalse(preview.isBlocked)
        XCTAssertTrue(preview.imageRouteLabel.contains("stay on this Mac"))
    }

    func testAMissingKeyNamesTheFixInsteadOfARoute() {
        let preview = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "openai"),
            provider: provider(id: "openai", name: "OpenAI", key: KeyBox("")),
            imageCount: 0,
            chosenLabel: "OpenAI · gpt-5 · Fast"
        )
        XCTAssertTrue(preview.isBlocked)
        XCTAssertEqual(preview.barLabel, "No API key for OpenAI", "the bar stays short enough to read")
        XCTAssertTrue(preview.blockerMessage?.contains("OpenAI") == true)
        XCTAssertTrue(preview.blockerMessage?.contains("Settings") == true)
        XCTAssertTrue(preview.blockerNeedsSettings, "the error line offers the way to Settings")
        XCTAssertEqual(preview.label, "OpenAI · gpt-5 · Fast", "the chosen route is still recorded")
        XCTAssertFalse(preview.barLabel.contains("gpt-5"), "a blocked bar never prints the route it will not run")
    }

    func testNoImagesMeansNoDestinationSentence() {
        let preview = ComposerRoutePreview.resolve(
            selection: ChatModelSelection(providerId: "deepseek"),
            provider: provider(vision: false),
            imageCount: 0,
            chosenLabel: "DeepSeek · deepseek-chat · Fast"
        )
        XCTAssertEqual(preview.imageRouteLabel, "")
    }
}
