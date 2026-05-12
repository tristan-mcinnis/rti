import XCTest

final class JSONExtractorTests: XCTestCase {

    private struct Payload: Decodable, Equatable {
        let name: String
        let count: Int
    }

    func testDecodesRawJSON() throws {
        let raw = #"{"name":"alpha","count":3}"#
        let decoded: Payload = try JSONExtractor.decode(raw)
        XCTAssertEqual(decoded, Payload(name: "alpha", count: 3))
    }

    func testStripsJSONFenceWithLanguageHint() throws {
        let raw = "```json\n{\"name\":\"alpha\",\"count\":3}\n```"
        let decoded: Payload = try JSONExtractor.decode(raw)
        XCTAssertEqual(decoded, Payload(name: "alpha", count: 3))
    }

    func testStripsBareTripleBacktickFence() throws {
        let raw = "```\n{\"name\":\"alpha\",\"count\":3}\n```"
        let decoded: Payload = try JSONExtractor.decode(raw)
        XCTAssertEqual(decoded, Payload(name: "alpha", count: 3))
    }

    func testStripsTrailingWhitespaceInsideFence() throws {
        let raw = "```json\n{\"name\":\"alpha\",\"count\":3}\n```   "
        let decoded: Payload = try JSONExtractor.decode(raw)
        XCTAssertEqual(decoded, Payload(name: "alpha", count: 3))
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try JSONExtractor.decode("   ") as Payload) { err in
            guard case JSONExtractor.Error.emptyInput = err else {
                return XCTFail("expected .emptyInput, got \(err)")
            }
        }
    }

    func testInvalidJSONThrowsDecodeError() {
        XCTAssertThrowsError(try JSONExtractor.decode("not json") as Payload) { err in
            guard case JSONExtractor.Error.decode = err else {
                return XCTFail("expected .decode, got \(err)")
            }
        }
    }

    func testTryDecodeReturnsNilOnFailure() {
        let result: Payload? = JSONExtractor.tryDecode("not json")
        XCTAssertNil(result)
    }

    func testTryDecodeSucceedsThroughFences() {
        let raw = "```json\n{\"name\":\"alpha\",\"count\":3}\n```"
        let result: Payload? = JSONExtractor.tryDecode(raw)
        XCTAssertEqual(result, Payload(name: "alpha", count: 3))
    }

    func testStripFencesIdempotentOnUnfencedInput() {
        let raw = "  {\"x\":1}  "
        XCTAssertEqual(JSONExtractor.stripFences(raw), "{\"x\":1}")
    }
}
