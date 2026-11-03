import XCTest

/// Lives beside the render proofs because `RTITests` compiles no app sources.
final class SonioxClientUpgradeRequestTests: XCTestCase {
    func test_upgradeRequestSendsKeyAsBearerHeader() {
        let request = SonioxClient.upgradeRequest(url: SonioxClient.defaultURL, apiKey: "test-key")

        XCTAssertEqual(request.url, SonioxClient.defaultURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }
}
