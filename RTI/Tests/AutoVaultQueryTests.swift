import RTICore
import XCTest

/// Auto's vault query: a few salient terms of the new window, and no search
/// for a short window.
final class AutoVaultQueryTests: XCTestCase {
    private func words(_ count: Int, prefix: String = "word") -> String {
        (0 ..< count).map { "\(prefix)\(Self.letters($0))" }.joined(separator: " ")
    }

    /// A distinct alphabetic suffix per index: tokens split at digits.
    private static func letters(_ index: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        return "\(alphabet[index / 26 % 26])\(alphabet[index % 26])"
    }

    func testShortWindowGetsNoQuery() {
        XCTAssertNil(AutoVaultQuery.query(from: words(24)))
        XCTAssertNotNil(AutoVaultQuery.query(from: words(25)))
    }

    func testFillerDoesNotCountTowardATopicButCountsAsWords() {
        let filler = Array(repeating: "yeah so like you know", count: 10).joined(separator: " ")
        XCTAssertGreaterThanOrEqual(AutoVaultQuery.wordCount(filler), 25)
        XCTAssertNil(AutoVaultQuery.query(from: filler), "filler alone names no topic")
    }

    func testQueryKeepsAtMostTwelveDistinctTerms() throws {
        let query = try XCTUnwrap(AutoVaultQuery.query(from: words(60)))
        let terms = query.split(separator: " ")
        XCTAssertEqual(terms.count, AutoVaultQuery.maximumTerms)
        XCTAssertEqual(Set(terms).count, terms.count)
    }

    func testRepeatedTermsRankFirst() throws {
        let text = words(30) + " packaging packaging packaging pricing pricing"
        let query = try XCTUnwrap(AutoVaultQuery.query(from: text))
        XCTAssertEqual(query.split(separator: " ").prefix(2), ["packaging", "pricing"])
    }

    func testShortNumbersAndTimestampsAreDropped() {
        let terms = AutoVaultQuery.salientTerms(in: "12 30 2025 launch 12 30")
        XCTAssertEqual(terms, ["launch", "2025"], "equal counts: the longer term first")
    }

    func testChineseCountsAsWordsAndKeepsBigrams() throws {
        // 50 characters is 25 words.
        let text = String(repeating: "包装价格消费者", count: 8)
        XCTAssertGreaterThanOrEqual(AutoVaultQuery.wordCount(text), 25)
        let query = try XCTUnwrap(AutoVaultQuery.query(from: text))
        XCTAssertTrue(query.contains("包装"))
        // The query survives the search tokenizer as the same terms.
        XCTAssertEqual(VaultSearch.tokenize(query), query.split(separator: " ").map(String.init))
    }

    func testChineseFillerBigramsDoNotCrowdOutTheTopic() throws {
        let sentence = "我们觉得这个包装就是一个问题，然后价格什么的，其实消费者就是很在意包装和价格。"
        let text = String(repeating: sentence, count: 3)
        let terms = try XCTUnwrap(AutoVaultQuery.query(from: text)).split(separator: " ").map(String.init)
        XCTAssertEqual(Array(terms.prefix(2)), ["包装", "价格"], "the repeated topic words rank first")
        XCTAssertTrue(terms.contains("消费"))
        let filler: Set = ["我们", "觉得", "这个", "就是", "一个", "然后", "什么", "其实", "们觉", "个包", "装就"]
        XCTAssertTrue(filler.isDisjoint(with: terms), "filler and cross-word bigrams never count: \(terms)")
    }
}
