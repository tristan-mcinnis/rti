import XCTest

final class ChunkPolicyTests: XCTestCase {

    // MARK: - Empty / trivial

    func test_emptyString_returnsNoChunks() {
        XCTAssertTrue(ChunkPolicy.split("").isEmpty)
    }

    func test_whitespaceOnly_returnsNoChunks() {
        XCTAssertTrue(ChunkPolicy.split("   \n\n  ").isEmpty)
    }

    func test_shortText_singleChunk() {
        let result = ChunkPolicy.split("hello world")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "hello world")
        XCTAssertEqual(result[0].idx, 0)
    }

    // MARK: - Paragraph-greedy packing

    func test_paragraphsWithinWindow_packedIntoSingleChunk() {
        let text = ["one", "two", "three"].joined(separator: "\n\n")
        let result = ChunkPolicy.split(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("one"))
        XCTAssertTrue(result[0].text.contains("two"))
        XCTAssertTrue(result[0].text.contains("three"))
    }

    func test_paragraphBreaksEmitChunks() {
        // Generate enough paragraphs to exceed 500 words.
        var paras: [String] = []
        for i in 0..<15 {
            paras.append("paragraph \(i) " + String(repeating: "word ", count: 40))
        }
        let text = paras.joined(separator: "\n\n")
        let result = ChunkPolicy.split(text)
        XCTAssertGreaterThan(result.count, 1, "Should produce multiple chunks")
        // All chunks should be non-empty.
        for chunk in result {
            XCTAssertFalse(chunk.text.isEmpty)
        }
        // Indices are sequential.
        for (i, chunk) in result.enumerated() {
            XCTAssertEqual(chunk.idx, i)
        }
    }

    // MARK: - Oversize paragraph

    func test_singleOversizeParagraph_emittedAsOwnChunk() {
        let big = Array(repeating: "word", count: 600).joined(separator: " ")
        let result = ChunkPolicy.split(big)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, big)
    }

    func test_oversizeParagraphThenNormal_yieldsTwoChunks() {
        let big = Array(repeating: "word", count: 600).joined(separator: " ")
        let small = "after the storm"
        let text = [big, small].joined(separator: "\n\n")
        let result = ChunkPolicy.split(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, big)
        XCTAssertTrue(result[1].text.contains("after the storm"))
    }

    // MARK: - Overlap

    func test_overlap_carriesTailIntoNextChunk() {
        // Create exactly enough paragraphs to force one boundary.
        // 500 words / ~40 words per para = ~12 paras fit. We use 25 to get at least one boundary.
        var paras: [String] = []
        for i in 0..<25 {
            paras.append("p\(i) " + String(repeating: "w ", count: 30))
        }
        let text = paras.joined(separator: "\n\n")
        let result = ChunkPolicy.split(text)
        XCTAssertGreaterThan(result.count, 1, "Should produce multiple chunks")

        // The last few words of chunk 0 should appear at the start of chunk 1.
        guard result.count >= 2 else { return }
        let c0Words = result[0].text.split(whereSeparator: { $0.isWhitespace })
        let c1Words = result[1].text.split(whereSeparator: { $0.isWhitespace })
        if c0Words.count > ChunkPolicy.overlapWords {
            let tail = c0Words.suffix(ChunkPolicy.overlapWords)
            let head = c1Words.prefix(ChunkPolicy.overlapWords)
            XCTAssertEqual(tail, head, "Overlap words should bridge the chunk boundary")
        }
    }

    // MARK: - Single paragraph longer than maxWords but not alone

    func test_oversizeParasSkipPacking_whenCurrentIsEmpty() {
        // First paragraph is oversize, second is normal — should yield two chunks.
        let big = Array(repeating: "word", count: 600).joined(separator: " ")
        let normal = "just a normal line"
        let text = [big, normal].joined(separator: "\n\n")
        let result = ChunkPolicy.split(text)
        XCTAssertEqual(result.count, 2)
    }
}
