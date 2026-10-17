import XCTest
import RTICore

final class JSONExtractorTests: XCTestCase {

    func testStripsJSONFenceWithLanguageHint() {
        let raw = "```json\n{\"name\":\"alpha\",\"count\":3}\n```"
        XCTAssertEqual(JSONExtractor.stripFences(raw), #"{"name":"alpha","count":3}"#)
    }

    func testStripsBareTripleBacktickFence() {
        let raw = "```\n{\"name\":\"alpha\",\"count\":3}\n```"
        XCTAssertEqual(JSONExtractor.stripFences(raw), #"{"name":"alpha","count":3}"#)
    }

    func testStripsTrailingWhitespaceInsideFence() {
        let raw = "```json\n{\"name\":\"alpha\",\"count\":3}\n```   "
        XCTAssertEqual(JSONExtractor.stripFences(raw), #"{"name":"alpha","count":3}"#)
    }

    func testStripFencesIdempotentOnUnfencedInput() {
        let raw = "  {\"x\":1}  "
        XCTAssertEqual(JSONExtractor.stripFences(raw), "{\"x\":1}")
    }

    // MARK: - Lenient array decode

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
