import XCTest
import RTICore

final class LLMErrorTests: XCTestCase {

    // MARK: - userMessage

    func test_userMessage_unauthorized_mentionsSettings() {
        let msg = LLMError.unauthorized.userMessage
        XCTAssertTrue(msg.contains("401"))
        XCTAssertTrue(msg.contains("Settings"))
    }

    func test_userMessage_missingAPIKey_mentionsSettings() {
        let msg = LLMError.missingAPIKey.userMessage
        XCTAssertTrue(msg.contains("Settings"))
    }

    func test_userMessage_httpError_includesCodeAndBody() {
        let msg = LLMError.httpError(500, "internal server error").userMessage
        XCTAssertTrue(msg.contains("500"))
        XCTAssertTrue(msg.contains("internal server error"))
    }

    func test_userMessage_streamError_includesDetail() {
        let msg = LLMError.streamError("connection reset").userMessage
        XCTAssertTrue(msg.contains("connection reset"))
    }

    func test_userMessage_badResponse_isNonEmpty() {
        XCTAssertFalse(LLMError.badResponse.userMessage.isEmpty)
    }

    // MARK: - isAuth

    func test_isAuth_trueForUnauthorized() {
        XCTAssertTrue(LLMError.unauthorized.isAuth)
    }

    func test_isAuth_trueForMissingAPIKey() {
        XCTAssertTrue(LLMError.missingAPIKey.isAuth)
    }

    func test_isAuth_falseForHttpError() {
        XCTAssertFalse(LLMError.httpError(500, "x").isAuth)
    }

    func test_isAuth_falseForStreamError() {
        XCTAssertFalse(LLMError.streamError("x").isAuth)
    }

    func test_isAuth_falseForBadResponse() {
        XCTAssertFalse(LLMError.badResponse.isAuth)
    }
}
