import RTICore
import XCTest

/// Real source reader, prompt and writer; injected completion, no network or vault.
@MainActor
final class SessionOutputGeneratorTests: XCTestCase {
    private var root: URL!
    private let transcript = "`00:12` **Remote speaker 1:** I will send the brief on Friday.\n"

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-output-generator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try transcript.write(to: root.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "Human summary".write(to: root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func route() -> ChatRouteConfiguration {
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

    private var recipe: SessionOutputRecipe {
        .builtIn(.decisionLog, resolve: { _ in "List supported decisions only." })
    }

    func testPromptUsesArchivedIdentityAndProvenanceMatchesSource() async throws {
        let names = try JSONEncoder().encode(["Remote speaker 1": "Riley"])
        try names.write(to: root.appendingPathComponent("speaker-names.json"))
        let metadata = try JSONSerialization.data(withJSONObject: [
            "mode": "Interview", "workstream": "Fixture study", "calendarTitle": "Fixture interview"
        ])
        try metadata.write(to: root.appendingPathComponent("session.json"))
        let expected = transcript
        let artifact = try await SessionOutputGenerator.generate(
            recipe: recipe, sessionDirectory: root, folderName: "fixture-session", route: route()
        ) { messages, frozen in
            let prompt = messages.first?.content ?? ""
            XCTAssertTrue(prompt.contains("Riley"))
            XCTAssertTrue(prompt.contains("Fixture study"))
            XCTAssertTrue(prompt.contains("Interview"))
            XCTAssertTrue(prompt.contains("Friday"))
            XCTAssertTrue(messages.allSatisfy { $0.images == nil })
            XCTAssertEqual(frozen.provider.model, "fixture-model")
            return LLMClient.CollectedResponse(text: "Supported decision record.", finishReason: "stop", reasoningCharacters: 0)
        }
        let body = try String(contentsOf: artifact.url, encoding: .utf8)
        let provenance = try XCTUnwrap(SessionOutputMarkdown.parseProvenance(body))
        XCTAssertEqual(provenance.sourceHash, PromptDefaults.fnv1a(expected))
        XCTAssertEqual(provenance.sourceBytes, expected.utf8.count)
        XCTAssertEqual(provenance.mode, "Interview")
        XCTAssertEqual(provenance.model, "fixture-model")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript.md"), encoding: .utf8), expected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("summary.md"), encoding: .utf8), "Human summary")
    }

    func testLinkedTranscriptIsRefusedBeforeTransport() async throws {
        let source = root.appendingPathComponent("transcript.md")
        let other = root.appendingPathComponent("other.txt")
        try "Not a transcript".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        await assertSourceRefused("transcript.md")
    }

    func testLinkedMetadataIsRefusedBeforeTransport() async throws {
        let other = root.appendingPathComponent("other.json")
        try "{}".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session.json"), withDestinationURL: other)
        await assertSourceRefused("session.json")
    }

    private func assertSourceRefused(_ name: String) async {
        do {
            _ = try await SessionOutputGenerator.generate(
                recipe: recipe, sessionDirectory: root, folderName: "fixture", route: route()
            ) { _, _ in
                XCTFail("an unsafe source reached transport")
                throw LLMError.badResponse
            }
            XCTFail("unsafe source accepted")
        } catch {
            XCTAssertEqual(error as? SessionOutputError, .unsafeSource(name))
        }
        XCTAssertTrue(SessionOutputStore.list(in: root).isEmpty)
    }

    func testProviderFailureIsNotReportedAsEmptyOutput() async {
        do {
            _ = try await SessionOutputGenerator.generate(
                recipe: recipe, sessionDirectory: root, folderName: "fixture", route: route()
            ) { _, _ in throw LLMError.unauthorized }
            XCTFail("failed request was saved")
        } catch {
            XCTAssertEqual(error as? SessionOutputError, .requestFailed(LLMError.unauthorized.userMessage))
        }
        XCTAssertTrue(SessionOutputStore.list(in: root).isEmpty)
    }

    func testEmptyAndTruncatedResponsesLeaveNoArtifacts() async {
        for truncated in [false, true] {
            do {
                _ = try await SessionOutputGenerator.generate(
                    recipe: recipe, sessionDirectory: root, folderName: "fixture", route: route()
                ) { _, _ in
                    LLMClient.CollectedResponse(text: truncated ? "partial" : "", finishReason: truncated ? "length" : "stop", reasoningCharacters: 0)
                }
                XCTFail("invalid completion saved")
            } catch {
                XCTAssertEqual(error as? SessionOutputError, truncated ? .truncatedOutput : .emptyOutput)
            }
        }
        XCTAssertTrue(SessionOutputStore.list(in: root).isEmpty)
    }

    func testCancelledCompletionLeavesNoArtifacts() async {
        do {
            _ = try await SessionOutputGenerator.generate(
                recipe: recipe, sessionDirectory: root, folderName: "fixture", route: route()
            ) { _, _ in throw CancellationError() }
            XCTFail("cancelled completion saved")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(SessionOutputStore.list(in: root).isEmpty)
    }
}
