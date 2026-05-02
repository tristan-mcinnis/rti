import XCTest

final class DeepSeekErrorTests: XCTestCase {

    // MARK: - userMessage

    func test_userMessage_unauthorized_mentionsSettings() {
        let msg = DeepSeekError.unauthorized.userMessage
        XCTAssertTrue(msg.contains("401"))
        XCTAssertTrue(msg.contains("Settings"))
    }

    func test_userMessage_missingAPIKey_mentionsSettings() {
        let msg = DeepSeekError.missingAPIKey.userMessage
        XCTAssertTrue(msg.contains("Settings"))
    }

    func test_userMessage_httpError_includesCodeAndBody() {
        let msg = DeepSeekError.httpError(500, "internal server error").userMessage
        XCTAssertTrue(msg.contains("500"))
        XCTAssertTrue(msg.contains("internal server error"))
    }

    func test_userMessage_streamError_includesDetail() {
        let msg = DeepSeekError.streamError("connection reset").userMessage
        XCTAssertTrue(msg.contains("connection reset"))
    }

    func test_userMessage_badResponse_isNonEmpty() {
        XCTAssertFalse(DeepSeekError.badResponse.userMessage.isEmpty)
    }

    // MARK: - isAuth

    func test_isAuth_trueForUnauthorized() {
        XCTAssertTrue(DeepSeekError.unauthorized.isAuth)
    }

    func test_isAuth_trueForMissingAPIKey() {
        XCTAssertTrue(DeepSeekError.missingAPIKey.isAuth)
    }

    func test_isAuth_falseForHttpError() {
        XCTAssertFalse(DeepSeekError.httpError(500, "x").isAuth)
    }

    func test_isAuth_falseForStreamError() {
        XCTAssertFalse(DeepSeekError.streamError("x").isAuth)
    }

    func test_isAuth_falseForBadResponse() {
        XCTAssertFalse(DeepSeekError.badResponse.isAuth)
    }
}
