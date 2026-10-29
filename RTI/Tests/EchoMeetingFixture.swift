import Foundation
import RTICore

/// A synthetic call (invented text) with the speakers' echo on the mic: the
/// remote voice arrives directly on the system leg (speaker 1, "Speaker 1")
/// and again through the room on the mic leg (speaker 2, "Room speaker 1"),
/// 150 ms later, cut into final batches at other points, one word misheard.
/// The mic wearer (speaker 1 on the mic, "You") answers once. The last line
/// is still interim on both legs. `|` in a script marks a sub-word token
/// boundary, as the provider splits "Hangzhou" into "Hang" + "zhou".
enum EchoMeetingFixture {
    struct Frame {
        let channel: String
        let words: [SonioxWord]
    }

    static let remoteLines = [
        "We could run the first workshop in Hang|zhou on the fourth, then fly to Cheng|du after lunch.",
        "That leaves one slot for the client review.",
        "Yeah.",
    ]
    static let selfLine = "Fine by me. Book whatever works."
    static let interimLine = "So for now I'm putting the fourth"

    static var frames: [Frame] {
        let one = tokens(remoteLines[0], speaker: 1, at: 10_000)
        let oneEcho = tokens(remoteLines[0].replacingOccurrences(of: "Cheng|du", with: "Chang|do"), speaker: 2, at: 10_150)
        let two = tokens(remoteLines[1], speaker: 1, at: 16_000)
        let twoEcho = tokens(remoteLines[1], speaker: 2, at: 16_150)
        let mine = tokens(selfLine, speaker: 1, at: 19_500)
        let yeah = tokens(remoteLines[2], speaker: 1, at: 22_000)
        let yeahEcho = tokens(remoteLines[2], speaker: 2, at: 22_100)
        let open = tokens(interimLine, speaker: 1, at: 23_500, final: false)
        let openEcho = tokens(interimLine, speaker: 2, at: 23_650, final: false)
        return [
            // The system batch ends inside "Hangzhou"; the mic batch ends earlier.
            Frame(channel: "system", words: Array(one[..<9])),
            Frame(channel: "mic", words: Array(oneEcho[..<6])),
            Frame(channel: "system", words: Array(one[9...])),
            Frame(channel: "mic", words: Array(oneEcho[6...])),
            Frame(channel: "mic", words: Array(twoEcho[..<4])),
            Frame(channel: "system", words: two),
            Frame(channel: "mic", words: Array(twoEcho[4...])),
            Frame(channel: "mic", words: mine),
            Frame(channel: "system", words: yeah),
            Frame(channel: "mic", words: yeahEcho),
            Frame(channel: "system", words: open),
            Frame(channel: "mic", words: openEcho),
        ]
    }

    /// Feed every frame through the pipeline, in arrival order.
    static func replay(into pipeline: TranscriptPipeline) {
        for frame in frames { pipeline.process(words: frame.words, channel: frame.channel) }
    }

    /// One provider token per word (leading space) or per `|` piece, 250 ms apart.
    static func tokens(_ script: String, speaker: Int, at startMs: Int, final: Bool = true) -> [SonioxWord] {
        let pieces = script.split(separator: " ").flatMap { word -> [String] in
            let parts = word.split(separator: "|").map(String.init)
            return [" " + parts[0]] + parts.dropFirst()
        }
        return pieces.enumerated().map { index, text in
            let start = startMs + index * 250
            return SonioxWord(text: text, startMs: start, endMs: start + 200, speaker: speaker, confidence: 1,
                              isFinal: final, translationStatus: "none", language: nil, sourceLanguage: nil)
        }
    }
}
