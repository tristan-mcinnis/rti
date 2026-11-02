import XCTest
import RTICore

@MainActor
final class ToolExecutorTests: XCTestCase {
    func testUnknownToolReturnsUnavailableResultWithoutExecuting() async {
        var executor = ToolExecutor(tools: [])
        let result = await executor.execute(call(name: "missing"))

        XCTAssertFalse(result.executed)
        XCTAssertNil(result.status)
        XCTAssertEqual(result.toolName, "missing")
        XCTAssertEqual(result.resultText, "Tool 'missing' is not available.")
    }

    func testExecutesKnownToolAndSurfacesStatus() async {
        let tool = LLMToolDefinition(
            name: "echo",
            description: "Echo arguments",
            parameters: [:],
            execute: { arguments in "got \(arguments)" },
            runningStatus: "Echoing…"
        )
        var executor = ToolExecutor(tools: [tool])

        let result = await executor.execute(call(name: "echo", arguments: #"{"q":"one"}"#))

        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.toolName, "echo")
        XCTAssertEqual(result.status, "Echoing…")
        XCTAssertEqual(result.resultText, #"got {"q":"one"}"#)
    }

    func testToolLimitReturnsNudgeAfterAllowedCalls() async {
        var runCount = 0
        let tool = LLMToolDefinition(
            name: "search_vault",
            description: "Search",
            parameters: [:],
            execute: { _ in
                runCount += 1
                return "results"
            },
            runningStatus: "Searching…"
        )
        var executor = ToolExecutor(tools: [tool], maxCallsPerTurn: ["search_vault": 1])

        let first = await executor.execute(call(name: "search_vault"))
        let second = await executor.execute(call(name: "search_vault"))

        XCTAssertTrue(first.executed)
        XCTAssertFalse(second.executed)
        XCTAssertEqual(runCount, 1)
        XCTAssertTrue(second.resultText.contains("already used search_vault this turn"))
    }

    func testSearchCapCountsEverySearchToolTogetherAndSparesReading() async {
        let tools = ["search_vault", "grep_vault", "read_document"].map { name in
            LLMToolDefinition(name: name, description: name, parameters: [:], execute: { _ in "ok" }, runningStatus: nil)
        }
        var executor = ToolExecutor(tools: tools, searchLimits: .init(maxCallsPerTurn: 2, timeLimit: .seconds(5)))

        let first = await executor.execute(call(name: "search_vault"))
        let second = await executor.execute(call(name: "grep_vault"))
        let third = await executor.execute(call(name: "grep_vault"))
        let read = await executor.execute(call(name: "read_document"))

        XCTAssertTrue(first.executed)
        XCTAssertTrue(second.executed)
        XCTAssertFalse(third.executed)
        XCTAssertEqual(third.outcome, .refused)
        XCTAssertTrue(third.resultText.contains("answer the user now"))
        XCTAssertTrue(read.executed)
    }

    func testSearchPastItsTimeLimitStopsTheWaitAndTellsTheModelToAnswer() async {
        let slow = LLMToolDefinition(
            name: "search_vault", description: "", parameters: [:],
            execute: { _ in
                try await Task.sleep(for: .seconds(30))
                return "late"
            },
            runningStatus: nil
        )
        var executor = ToolExecutor(tools: [slow], searchLimits: .init(maxCallsPerTurn: 2, timeLimit: .milliseconds(50)))

        let result = await executor.execute(call(name: "search_vault"))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.resultText.contains("did not finish in time"))
        XCTAssertLessThan(result.elapsedMS, 5_000)
    }

    func testRetryOnceRunsAgainOnlyWhenAllowed() async throws {
        struct Failure: Error {}
        var runs = 0
        let value = try await RetryOnce.run(delay: .zero, shouldRetry: { _ in true }) {
            runs += 1
            if runs == 1 { throw Failure() }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(runs, 2)

        runs = 0
        do {
            _ = try await RetryOnce.run(delay: .zero, shouldRetry: { _ in false }) {
                runs += 1
                throw Failure()
            }
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(runs, 1)
    }

    func testThrownToolErrorBecomesModelVisibleResult() async {
        enum TestError: LocalizedError {
            case failed
            var errorDescription: String? { "boom" }
        }
        let tool = LLMToolDefinition(
            name: "explode",
            description: "Throws",
            parameters: [:],
            execute: { _ in throw TestError.failed },
            runningStatus: nil
        )
        var executor = ToolExecutor(tools: [tool])

        let result = await executor.execute(call(name: "explode"))

        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.status, "Running explode…")
        XCTAssertEqual(result.resultText, "Tool 'explode' failed: boom")
    }

    private func call(name: String, arguments: String = "{}") -> LLMToolCall {
        LLMToolCall(
            id: "call_\(name)",
            type: "function",
            function: .init(name: name, arguments: arguments)
        )
    }
}
