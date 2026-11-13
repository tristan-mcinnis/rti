import Foundation
import RTICore
import XCTest

/// Layer B of the research acceptance replay (recommendations 5.4): the same
/// invented fixture against the configured provider (DeepSeek by default)
/// with the shipped prompts, scored against `answer-key.json`. Opt-in and
/// local only: `RTI_EVAL_DEEPSEEK=1`. It sends only the invented fixture.
/// Results go under `.deriveddata/research-replay-eval/<stamp>/`, never the
/// repo: `score.json`, `summary.md`, and every exchange for reading or for
/// recording new `responses/`. `RTI_EVAL_STRICT=1` also fails the test when a
/// target is missed. Token counts are estimates from characters (the
/// collected response carries no usage), so cache hits are not reported.
@MainActor
final class ResearchReplayLiveEvalTests: RenderProofTestCase {
    private static let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".deriveddata/research-replay-eval", isDirectory: true)

    func testScoreTheShippedPromptsAgainstTheAnswerKey() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RTI_EVAL_DEEPSEEK"] == "1" else {
            throw XCTSkip("Set RTI_EVAL_DEEPSEEK=1 to score live model output (local only, never in CI)")
        }
        let key = try ResearchReplayFixture.answerKey()
        let checkpoints = ((key["guide"] as? [String: Any])?["checkpoints"] as? [[String: Any]] ?? []).compactMap { $0["minute"] as? Int }
        let client = LLMClient.shared
        let responder = try ResearchReplayResponder(lines: ResearchReplayFixture.lines()) { messages in
            try await client.collectDetailedResponse(messages: messages, smart: false, route: nil, timeoutOverride: 120).text
        }
        let began = Date()
        let result = try await ResearchReplayRun.run(responder, checkpointMinutes: checkpoints)
        let score = ResearchReplayScore(result, key: key)

        let stamp = ISO8601DateFormatter().string(from: began).replacingOccurrences(of: ":", with: "")
        let folder = Self.output.appendingPathComponent(stamp, isDirectory: true)
        try result.write(to: folder)
        var summary = score.summary
        summary["wallSeconds"] = Date().timeIntervalSince(began)
        summary["targets"] = targets(score, key: key).map { ["id": $0.id, "passed": $0.passed, "detail": $0.detail] }
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("score.json"))
        let lines = targets(score, key: key).map { "- \($0.passed ? "pass" : "MISS") \($0.id): \($0.detail)" }
            + ["", "Checks:"] + score.checks.map { "- \($0.passed ? "pass" : "miss") \($0.id): \($0.detail)" }
            + ["", "Forbidden: \(score.forbidden.isEmpty ? "none" : score.forbidden.joined(separator: "; "))"]
        try (["# Research replay, live eval \(stamp)", ""] + lines).joined(separator: "\n")
            .write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("Research replay live eval: \(folder.path)\n" + lines.joined(separator: "\n"))

        XCTAssertFalse(result.exchanges.isEmpty)
        guard environment["RTI_EVAL_STRICT"] == "1" else { return }
        for target in targets(score, key: key) {
            XCTAssertTrue(target.passed, "\(target.id): \(target.detail)")
        }
    }

    /// The section 5.4 targets.
    private func targets(_ score: ResearchReplayScore, key: [String: Any]) -> [ResearchReplayScore.Check] {
        let codebook = key["codebook"] as? [String: Any] ?? [:]
        let guide = key["guide"] as? [String: Any] ?? [:]
        let byID = Dictionary(score.checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func check(_ id: String) -> ResearchReplayScore.Check {
            byID[id] ?? .init(id: id, passed: false, detail: "not scored")
        }
        let tension = check("codebook.sweet-vs-sugar"), flag = check("auto.contradiction")
        return [
            .init(id: "codebook recall", passed: score.codebookRecall >= codebook["minRecall"] as? Double ?? 0.8,
                  detail: String(format: "%.0f%% of required cards", score.codebookRecall * 100)),
            .init(id: "no forbidden cards", passed: score.forbidden.isEmpty, detail: score.forbidden.joined(separator: "; ")),
            .init(id: "minute-34 contradiction", passed: tension.passed && flag.passed, detail: "tension: \(tension.detail); FLAG: \(flag.detail)"),
            .init(id: "guide position", passed: score.checkpointsRight >= guide["minCheckpointsRight"] as? Int ?? 8,
                  detail: "\(score.checkpointsRight) of 10 checkpoints"),
            check("auto.volume"), check("auto.template"), check("auto.mandarin"),
            .init(id: "input", passed: true, detail: "\(score.inputCharacters) characters, about \(score.estimatedTokensPerHour) tokens an hour, calls \(score.calls)"),
        ]
    }
}
