import Foundation
@testable import RTICore
import XCTest

final class ResearchModerationTests: XCTestCase {
    private let turns: [ResearchModeration.Turn] = [
        .init(id: "earlier", startMs: 120_000, text: "I bought the glass one.", moderator: false,
              label: "Them/S2", person: "S2", guideQuestion: "Q1", marker: nil, shown: nil),
        .init(id: "mic", startMs: 705_000, text: "You prefer paper, right?", moderator: true,
              label: "Me", person: nil, guideQuestion: "Q2", marker: "m1", shown: ["A"]),
        .init(id: "later", startMs: 754_000, text: "我只会买纸的。", moderator: false,
              label: "Them/S2", person: "S2", guideQuestion: "Q2", marker: "m1", shown: ["A"]),
        .init(id: "echo", startMs: 770_000, text: "I guess I would too.", moderator: false,
              label: "Them/S3", person: "S3", guideQuestion: "Q2", marker: "m1", shown: ["A"]),
    ]

    private func snapshot(_ action: ResearchModeration.Action, more: [ResearchModeration.Turn] = []) -> ResearchModeration {
        ResearchModeration(action: action, minutes: 10, endMs: 800_000, turns: turns + more,
                           roster: ["S2": "Seat 2", "S3": "Seat 3", "S4": "Seat 4"],
                           guideTitles: ["Q2": "Material choice"], guideOn: true)
    }

    private func citation(_ id: String, _ excerpt: String) -> [String: String] {
        ["id": id, "excerpt": excerpt]
    }

    private func reply(_ items: [[String: Any]]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
    }

    private func assertVerbatim(_ output: String, expected: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let pattern = try NSRegularExpression(pattern: #"\*\*Source \[[^\n]+?\*\* “([^”]+)”"#)
        let range = NSRange(output.startIndex..., in: output)
        let quoted = pattern.matches(in: output, range: range).compactMap { match in
            Range(match.range(at: 1), in: output).map { String(output[$0]) }
        }
        XCTAssertEqual(quoted, expected, file: file, line: line)
        for q in quoted {
            XCTAssertTrue(turns.contains { $0.text.range(of: q, options: .literal) != nil }, file: file, line: line)
        }
    }

    func testTensionCitesExactOriginalAndPlacesBothEnglishProbesBeforeMandarin() throws {
        let s = snapshot(.tension)
        let question = ["english": "When did you last make that choice?",
                        "citations": [citation("later", "我只会买纸的。")],
                        "suggestedMandarin": "上次是什么时候？"] as [String: Any]
        let another = ["english": "Can you give an example?", "citations": [citation("echo", "I guess I would too.")]] as [String: Any]
        let output = try s.render(reply([question, another]))
        XCTAssertTrue(output.hasPrefix("- **Suggested question for the moderator** When"))
        XCTAssertLessThan(try XCTUnwrap(output.range(of: "Can you give an example?")?.lowerBound),
                          try XCTUnwrap(output.range(of: "**Source")?.lowerBound))
        XCTAssertTrue(output.contains("[12:34, Them/S2] · Q2 Material choice · shown A"))
        XCTAssertTrue(output.contains("**Suggested question in Mandarin** 上次是什么时候？"))
        XCTAssertTrue(output.contains("wǒ"))
        try assertVerbatim(output, expected: ["我只会买纸的。", "I guess I would too."])
        XCTAssertFalse(s.transcript.contains("I bought the glass one."))
        let repeated = try s.render(reply(Array(repeating: question, count: 6)))
        XCTAssertLessThanOrEqual(repeated.components(separatedBy: "- **Suggested").count - 1, 3)
    }

    func testSaidVsDoneAllowsEarlierBehaviorOnlyForTheSameVerifiedParticipant() throws {
        let s = snapshot(.saidVsDone)
        let item = ["english": "The reported purchase differs from the stated preference.",
                    "citations": [citation("earlier", "I bought the glass one."), citation("later", "我只会买纸的。")]] as [String: Any]
        let output = try s.render(reply([item]))
        XCTAssertTrue(output.contains("[02:00, Them/S2]"))
        try assertVerbatim(output, expected: ["I bought the glass one.", "我只会买纸的。"])
        let wrong = ["english": "They contradicted themselves.", "citations": [citation("earlier", "glass"), citation("echo", "too.")]] as [String: Any]
        XCTAssertEqual(try s.render(reply([wrong])), "No supported finding in the selected window.")
    }

    func testEchoUsesConfirmedRosterAndSuppressesNamesWhenAnyParticipantIsUnverified() throws {
        let s = snapshot(.echo)
        let item = ["english": "Probe how the second view formed.", "citations": [citation("later", "我只会买纸的。"), citation("echo", "I guess I would too.")]] as [String: Any]
        let output = try s.render(reply([item]))
        try assertVerbatim(output, expected: ["我只会买纸的。", "I guess I would too."])
        XCTAssertTrue(output.contains("No captured turn for Q2 in this window: Seat 4"))
        let unknown = ResearchModeration.Turn(id: "unverified", startMs: 775_000, text: "I guess I would too.", moderator: false,
                                              label: "Them", person: nil, guideQuestion: "Q2", marker: nil, shown: nil)
        let fallback = try XCTUnwrap(snapshot(.echo, more: [unknown]).localAnswer)
        XCTAssertTrue(fallback.hasPrefix("speaker labels too uncertain for this check"))
        XCTAssertFalse(fallback.contains("Seat 4"))
        XCTAssertFalse(fallback.contains("Them/S"))
        try assertVerbatim(fallback, expected: ["I guess I would too."])
    }

    func testRefusesGroupClaimsFromOneSpeakerAndOneWordAssent() throws {
        let s = snapshot(.themes)
        let unsupported: [String: Any] = ["english": "The group chose paper.", "origin": "participant",
                                          "leadingAssent": false, "citations": [citation("later", "我只会买纸的。")]]
        XCTAssertEqual(try s.render(reply([unsupported])), "No supported finding in the selected window.")
        let yes = ResearchModeration.Turn(id: "yes", startMs: 775_000, text: "是的。", moderator: false,
                                          label: "Them", person: nil, guideQuestion: "Q2", marker: nil, shown: nil)
        let leading: [String: Any] = ["english": "A preference for paper emerged.", "origin": "moderator",
                                      "leadingAssent": false, "citations": [citation("mic", "You prefer paper, right?"), citation("yes", "是的。")]]
        XCTAssertEqual(try snapshot(.themes, more: [yes]).render(reply([leading])), "No supported finding in the selected window.")
    }

    func testThemesRejectLeadingAgreementAndInventedOrStitchedQuotes() throws {
        let s = snapshot(.themes)
        let good = ["english": "Paper was mentioned in response to the moderator.",
                    "origin": "moderator", "leadingAssent": false,
                    "citations": [citation("mic", "You prefer paper, right?"), citation("later", "我只会买纸的。")]] as [String: Any]
        var leading = good; leading["leadingAssent"] = true
        var invented = good; invented["citations"] = [citation("later", "I prefer paper.")]
        var stitched = good; stitched["citations"] = [citation("later", "我只会买纸的。I guess")]
        let output = try s.render(reply([leading, invented, stitched, good]))
        XCTAssertEqual(output.components(separatedBy: "Raised after a moderator question").count - 1, 1)
        try assertVerbatim(output, expected: ["You prefer paper, right?", "我只会买纸的。"])
        XCTAssertEqual(s.render("unverified provider prose"), "The reply could not be checked against the transcript.")
    }
}
