import Foundation
import RTICore
import XCTest

/// Live eval of the chat actions (2026-11-15): the invented 60-minute research
/// group (`RTI/Tests/Fixtures/ResearchReplay`) replayed through the real
/// session, then every research action and three typed questions sent through
/// the real `LLMController` with the configured provider, at minute 30 and 60.
/// Each action starts in a new chat, so no answer leans on another. Opt-in and
/// local only: `RTI_EVAL_DEEPSEEK=1`. It sends only the invented fixture.
/// Output goes to `.deriveddata/chat-prompt-eval/<stamp>/` (never the repo):
/// the transcript each answer saw and every answer, for a judge to score.
@MainActor
final class ChatPromptLiveEvalTests: RenderProofTestCase {
    private static let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".deriveddata/chat-prompt-eval", isDirectory: true)

    private static let actions = ["quickRecap", "recap", "themes", "keyTensions", "probe", "saidVsDone", "followups",
                                  "assist", "answerLatest"]
    private static let questions = ["What are the themes so far?",
                                    "What did they say about cleaning the cup?",
                                    "总结一下目前大家对价格的看法"]

    func testEveryChatActionOnTheInventedGroup() async throws {
        guard ProcessInfo.processInfo.environment["RTI_EVAL_DEEPSEEK"] == "1" else {
            throw XCTSkip("Set RTI_EVAL_DEEPSEEK=1 to run the chat actions against the live provider (local only)")
        }
        ChatPromptLiveEvalTests.installEvalKey()
        let llm = LLMController.shared
        llm.callTypeStore.active = .research
        let session = SessionCoordinator.shared
        let start = Date().addingTimeInterval(-3600)
        session.beginTranscriptReplayForProof(startedAt: start)
        defer { session.endTranscriptReplayForProof() }
        let sessionID = try XCTUnwrap(session.currentSessionId)
        let guide = GuideSessionController.shared
        guide.start(sessionID: sessionID, guide: try ResearchReplayFixture.guide(), guideURL: ResearchReplayFixture.guideURL,
                    group: "G1", roster: [], rosterURL: nil, startedAt: start)
        defer { guide.endSession(sessionID) }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = Self.output.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let batches = try ResearchReplayFixture.batches()
        var next = 0
        var records: [[String: Any]] = []
        var guideTick = 240
        for minute in [30, 60] {
            while next < batches.count, batches[next].arrivalMs <= minute * 60000 {
                // Guide passes every 4 replayed minutes, as live, so sources
                // carry real guide positions.
                if batches[next].arrivalMs >= guideTick * 1000 {
                    _ = await guide.generateLive(sessionId: sessionID, at: start.addingTimeInterval(TimeInterval(guideTick)))
                    guideTick += 240
                }
                session.receiveTranscriptWordsForProof(batches[next].tokens, channel: batches[next].leg)
                next += 1
            }
            // "Now" is this minute of the call.
            session.setStartedAtForProof(Date().addingTimeInterval(-TimeInterval(minute * 60)))
            try llm.recentTranscriptText(fullWindow: true)
                .write(to: folder.appendingPathComponent("transcript-min\(minute).txt"), atomically: true, encoding: .utf8)
            // `RTI_EVAL_ONLY=themes,recap` runs just those actions.
            let only = ProcessInfo.processInfo.environment["RTI_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
            for item in Self.actions.map({ ("action", $0) }) + Self.questions.map({ ("ask", $0) })
                where only?.contains(item.1) ?? true {
                llm.newChat()
                try await Task.sleep(for: .milliseconds(300))
                let began = Date()
                if item.0 == "action" { llm.perform(actionID: item.1) } else { llm.sendAskAnything(item.1) }
                let answer = try await waitForAnswer(llm, timeout: 180)
                records.append([
                    "minute": minute, "kind": item.0, "id": item.1,
                    "seconds": Date().timeIntervalSince(began),
                    "answer": answer ?? "", "error": llm.lastError ?? "",
                ])
                print("CHAT EVAL min \(minute) \(item.1): \(answer?.count ?? 0) chars, error: \(llm.lastError ?? "none"), dropped: \(ResearchModeration.lastDropReasons)")
            }
        }
        llm.newChat()
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("answers.json"))
        var markdown = ["# Chat prompt eval \(stamp)", ""]
        for record in records {
            markdown += ["## min \(record["minute"]!) · \(record["kind"]!) · \(record["id"]!)", "",
                         (record["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no answer: \(record["error"]!))", ""]
        }
        try markdown.joined(separator: "\n").write(to: folder.appendingPathComponent("answers.md"), atomically: true, encoding: .utf8)
        print("Chat prompt eval: \(folder.path)")
        XCTAssertFalse(records.isEmpty)
    }

    /// Tests keep their own throwaway Application Support folder, so the live
    /// evals read the provider key from `RTI_EVAL_DEEPSEEK_KEY` (fetched from
    /// 1Password by the caller, never printed) into that folder only.
    static func installEvalKey() {
        if let key = ProcessInfo.processInfo.environment["RTI_EVAL_DEEPSEEK_KEY"], !key.isEmpty {
            CredentialStore.set(key, for: "deepseek")
        }
    }

    /// The newest assistant answer once the turn has ended, or nil.
    private func waitForAnswer(_ llm: LLMController, timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var sawStream = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if llm.streaming { sawStream = true; continue }
            let last = llm.entries.last
            if last?.role == "assistant", !(last?.text.isEmpty ?? true) { return last?.text }
            if sawStream || llm.lastError != nil { return nil }
        }
        return nil
    }
}
