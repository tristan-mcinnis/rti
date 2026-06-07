import RTICore
import XCTest

/// Characterizes the SSE parser extracted from LLMClient: content/reasoning
/// deltas, the [DONE] sentinel, mid-stream errors, tool-call assembly across
/// chunks, and the lines it ignores. Pins the streaming behavior so the
/// client's network loop can be refactored over it safely.
final class SSEStreamParserTests: XCTestCase {
    private func dataLine(_ json: String) -> String {
        "data: \(json)"
    }

    func test_contentDelta_emitsContent() {
        var p = SSEStreamParser()
        let events = p.consume(line: dataLine(#"{"choices":[{"delta":{"content":"hello"}}]}"#))
        XCTAssertEqual(events, [.content("hello")])
    }

    func test_reasoningDelta_emitsReasoning() {
        var p = SSEStreamParser()
        let events = p.consume(line: dataLine(#"{"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#))
        XCTAssertEqual(events, [.reasoning("thinking")])
    }

    func test_reasoningAndContentInOneChunk_emitsBothReasoningFirst() {
        var p = SSEStreamParser()
        let events = p.consume(line: dataLine(#"{"choices":[{"delta":{"content":"hi","reasoning_content":"r"}}]}"#))
        XCTAssertEqual(events, [.reasoning("r"), .content("hi")])
    }

    func test_emptyContent_emitsNothing() {
        var p = SSEStreamParser()
        XCTAssertEqual(p.consume(line: dataLine(#"{"choices":[{"delta":{"content":""}}]}"#)), [])
    }

    func test_doneSentinel_emitsDone() {
        var p = SSEStreamParser()
        XCTAssertEqual(p.consume(line: "data: [DONE]"), [.done])
    }

    func test_midStreamError_emitsStreamError() {
        var p = SSEStreamParser()
        let events = p.consume(line: dataLine(#"{"error":{"message":"rate limited"}}"#))
        XCTAssertEqual(events, [.streamError("rate limited")])
    }

    func test_commentLine_isIgnored() {
        var p = SSEStreamParser()
        XCTAssertEqual(p.consume(line: ": keep-alive"), [])
    }

    func test_nonDataLine_isIgnored() {
        var p = SSEStreamParser()
        XCTAssertEqual(p.consume(line: "event: ping"), [])
    }

    func test_malformedJSON_isIgnored() {
        var p = SSEStreamParser()
        XCTAssertEqual(p.consume(line: dataLine("{not json")), [])
    }

    func test_finishReason_isCaptured() {
        var p = SSEStreamParser()
        _ = p.consume(line: dataLine(#"{"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}"#))
        XCTAssertEqual(p.finishReason, "stop")
    }

    func test_toolCalls_assembleAcrossChunksInIndexOrder() {
        var p = SSEStreamParser()
        // index 1 arrives before index 0 to prove ordering by index, not arrival.
        _ = p.consume(line: dataLine(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#))
        _ = p.consume(line: dataLine(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{\"k\":"}}]}}]}"#))
        _ = p.consume(line: dataLine(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#))
        let calls = p.assembledToolCalls()
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        XCTAssertEqual(calls.map(\.function.name), ["first", "second"])
        XCTAssertEqual(calls[0].function.arguments, #"{"k":1}"#)
    }

    func test_toolCallMissingName_isDropped() {
        var p = SSEStreamParser()
        _ = p.consume(line: dataLine(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"arguments":"{}"}}]}}]}"#))
        XCTAssertTrue(p.assembledToolCalls().isEmpty)
    }
}
