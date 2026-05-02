import XCTest

final class SonioxFailureTests: XCTestCase {

    // MARK: - shouldRetry

    func test_shouldRetry_falseForAuth() {
        XCTAssertFalse(SonioxFailure.auth.shouldRetry)
    }

    func test_shouldRetry_falseForClientBug() {
        XCTAssertFalse(SonioxFailure.clientBug("bad request").shouldRetry)
    }

    func test_shouldRetry_trueForTransient() {
        XCTAssertTrue(SonioxFailure.transient(reason: "network").shouldRetry)
    }

    func test_shouldRetry_trueForUnknown() {
        XCTAssertTrue(SonioxFailure.unknown(code: 599, body: "?").shouldRetry)
    }

    // MARK: - isAuth

    func test_isAuth_trueOnlyForAuth() {
        XCTAssertTrue(SonioxFailure.auth.isAuth)
        XCTAssertFalse(SonioxFailure.clientBug("x").isAuth)
        XCTAssertFalse(SonioxFailure.transient(reason: "x").isAuth)
        XCTAssertFalse(SonioxFailure.unknown(code: 500, body: "x").isAuth)
    }

    // MARK: - userMessage(didOpen:) — phase awareness

    func test_userMessage_auth_mentionsSettings_regardlessOfPhase() {
        XCTAssertTrue(SonioxFailure.auth.userMessage(didOpen: false).contains("Settings"))
        XCTAssertTrue(SonioxFailure.auth.userMessage(didOpen: true).contains("Settings"))
    }

    func test_userMessage_transient_handshakeMentionsNetwork() {
        let msg = SonioxFailure.transient(reason: "dns").userMessage(didOpen: false)
        // Pre-open: actionable network/proxy advice.
        XCTAssertTrue(
            msg.localizedCaseInsensitiveContains("internet") ||
            msg.localizedCaseInsensitiveContains("proxy")
        )
    }

    func test_userMessage_transient_postOpenSaysReconnecting() {
        let msg = SonioxFailure.transient(reason: "1006").userMessage(didOpen: true)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("reconnect"))
    }

    func test_userMessage_transient_differsByPhase() {
        let pre = SonioxFailure.transient(reason: "x").userMessage(didOpen: false)
        let post = SonioxFailure.transient(reason: "x").userMessage(didOpen: true)
        XCTAssertNotEqual(pre, post,
            "Pre-open and post-open transient failures must read differently — that's the whole point of phase-aware copy.")
    }

    func test_userMessage_clientBug_includesDetail() {
        let msg = SonioxFailure.clientBug("bad audio_format").userMessage(didOpen: false)
        XCTAssertTrue(msg.contains("bad audio_format"))
    }

    func test_userMessage_unknown_includesCodeAndBody() {
        let msg = SonioxFailure.unknown(code: 418, body: "I'm a teapot").userMessage(didOpen: true)
        XCTAssertTrue(msg.contains("418"))
        XCTAssertTrue(msg.contains("teapot"))
    }

    // MARK: - fromSonioxApplicationError — code → case mapping

    func test_fromApp_400_isClientBug() {
        switch SonioxFailure.fromSonioxApplicationError(code: 400, detail: "bad") {
        case .clientBug(let detail): XCTAssertEqual(detail, "bad")
        default: XCTFail("expected clientBug")
        }
    }

    func test_fromApp_401_402_403_isAuth() {
        for code in [401, 402, 403] {
            switch SonioxFailure.fromSonioxApplicationError(code: code, detail: "x") {
            case .auth: break
            default: XCTFail("code \(code) expected to map to .auth")
            }
        }
    }

    func test_fromApp_408_429_isTransient() {
        for code in [408, 429] {
            switch SonioxFailure.fromSonioxApplicationError(code: code, detail: "rate limit") {
            case .transient: break
            default: XCTFail("code \(code) expected to map to .transient")
            }
        }
    }

    func test_fromApp_5xx_isTransient() {
        for code in [500, 502, 503, 504] {
            switch SonioxFailure.fromSonioxApplicationError(code: code, detail: "server") {
            case .transient: break
            default: XCTFail("code \(code) expected to map to .transient")
            }
        }
    }

    func test_fromApp_unrecognisedCode_isUnknown() {
        switch SonioxFailure.fromSonioxApplicationError(code: 418, detail: "teapot") {
        case .unknown(let code, let body):
            XCTAssertEqual(code, 418)
            XCTAssertEqual(body, "teapot")
        default:
            XCTFail("expected unknown")
        }
    }

    // MARK: - fromTransport always transient

    func test_fromTransport_isTransient() {
        switch SonioxFailure.fromTransport(reason: "anything") {
        case .transient: break
        default: XCTFail("transport drops should always classify as .transient")
        }
    }
}
