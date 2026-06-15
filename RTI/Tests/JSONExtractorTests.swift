import XCTest
import RTICore

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

    // MARK: - Lenient array decode (the analysis robustness fix)

    private struct Item: Decodable, Equatable { let id: String; let n: Int }

    func testLenientArrayDecodesAllGood() {
        let raw = #"{"items":[{"id":"a","n":1},{"id":"b","n":2}]}"#
        let items: [Item] = JSONExtractor.decodeArrayLenient(raw, key: "items")
        XCTAssertEqual(items, [Item(id: "a", n: 1), Item(id: "b", n: 2)])
    }

    func testLenientArraySkipsOneMalformedItemKeepsRest() {
        // Middle item is missing required "n" — it must be skipped, not sink the batch.
        let raw = #"{"items":[{"id":"a","n":1},{"id":"b"},{"id":"c","n":3}]}"#
        let items: [Item] = JSONExtractor.decodeArrayLenient(raw, key: "items")
        XCTAssertEqual(items, [Item(id: "a", n: 1), Item(id: "c", n: 3)])
    }

    func testLenientArrayRecoversFromTruncatedTail() {
        // Response cut off mid-array (no closing of last object or the array) —
        // every complete item before the cut must survive.
        let raw = #"{"items":[{"id":"a","n":1},{"id":"b","n":2},{"id":"c","n"#
        let items: [Item] = JSONExtractor.decodeArrayLenient(raw, key: "items")
        XCTAssertEqual(items, [Item(id: "a", n: 1), Item(id: "b", n: 2)])
    }

    func testLenientArrayHandlesFencesAndBrachesInStrings() {
        // Braces inside string values must not confuse the brace matcher.
        let raw = "```json\n{\"items\":[{\"id\":\"x}{\",\"n\":7}]}\n```"
        let items: [Item] = JSONExtractor.decodeArrayLenient(raw, key: "items")
        XCTAssertEqual(items, [Item(id: "x}{", n: 7)])
    }

    func testLenientArrayMissingKeyReturnsEmpty() {
        let items: [Item] = JSONExtractor.decodeArrayLenient(#"{"other":[]}"#, key: "items")
        XCTAssertTrue(items.isEmpty)
    }
}
