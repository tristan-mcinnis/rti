import Foundation

/// Who most likely spoke a turn. Live labels are off by default, so every
/// system-leg turn shares one speaker ID and the label alone never tells the
/// moderator from a respondent. This is a hint for the guide, codebook and
/// Auto prompts, never a speaker identity.
public enum SpeechRole: String, Codable, Sendable {
    case moderator
    case respondent
    case unknown
}

/// Character 4-gram index of a guide's question and probe wording. Built once
/// per session; a match is a moderator reading or paraphrasing a question.
public struct GuideMatcher: Sendable {
    struct Entry: Sendable {
        let qid: String
        let index: Int
        let grams: Set<UInt64>
        let instruction: Bool
    }

    /// Dice overlap of character 4-grams that counts as the same wording.
    public static let threshold = 0.35
    /// Fewer shared 4-grams than this is never a match, however short the text.
    static let minimumShared = 3

    let entries: [Entry]

    public init(guide: GuideDocument) {
        var entries: [Entry] = []
        for (index, question) in guide.questions.enumerated() {
            let instruction = Self.isInstruction(question)
            let wordings = [question.en, question.zh] + question.probes.flatMap { [$0.en, $0.zh] }
            for wording in wordings {
                let grams = TurnRoles.grams(Self.strippingTopic(wording), size: 4)
                guard grams.count >= Self.minimumShared else { continue }
                entries.append(Entry(qid: question.qid, index: index, grams: grams, instruction: instruction))
            }
        }
        self.entries = entries
        var postings: [UInt64: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            for gram in entry.grams {
                postings[gram, default: []].append(index)
            }
        }
        self.postings = postings
    }

    /// Which entries hold each gram, so a line is scored by looking up its
    /// own few grams instead of testing every guide wording.
    private let postings: [UInt64: [Int]]

    /// A "Moderator to…" item is an instruction to the moderator, not a
    /// question anyone answers.
    public static func isInstruction(_ question: GuideDocument.Question) -> Bool {
        question.en.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("moderator to")
    }

    /// Workbook exports put a topic in square brackets before the wording.
    public static func strippingTopic(_ wording: String) -> String {
        let trimmed = wording.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[", let end = trimmed.firstIndex(of: "]") else { return trimmed }
        return String(trimmed[trimmed.index(after: end)...])
    }

    /// The best score per question at or above the threshold.
    func scores(_ text: String) -> [(qid: String, index: Int, score: Double, instruction: Bool)] {
        let grams = TurnRoles.grams(text, size: 4)
        guard grams.count >= Self.minimumShared else { return [] }
        var sharedCounts: [Int: Int] = [:]
        for gram in grams {
            for index in postings[gram] ?? [] {
                sharedCounts[index, default: 0] += 1
            }
        }
        var best: [String: (index: Int, score: Double, instruction: Bool)] = [:]
        for (entryIndex, shared) in sharedCounts.sorted(by: { $0.key < $1.key }) {
            let entry = entries[entryIndex]
            guard shared >= Self.minimumShared else { continue }
            let score = 2 * Double(shared) / Double(grams.count + entry.grams.count)
            guard score >= Self.threshold, score > (best[entry.qid]?.score ?? 0) else { continue }
            best[entry.qid] = (entry.index, score, entry.instruction)
        }
        return best.map { (qid: $0.key, index: $0.value.index, score: $0.value.score, instruction: $0.value.instruction) }
    }

    /// The text reads or paraphrases some guide wording.
    public func matches(_ text: String) -> Bool {
        !scores(text).isEmpty
    }

    /// The question a moderator line asks. Instruction items never count.
    /// A repeated block (the same wording in two sections) resolves to the
    /// nearest copy at or after `currentIndex`, else the nearest before it.
    public func question(asked text: String, near currentIndex: Int?) -> String? {
        let candidates = scores(text).filter { !$0.instruction }
        guard let top = candidates.map(\.score).max() else { return nil }
        let tied = candidates.filter { $0.score >= top - 0.05 }
        let current = currentIndex ?? 0
        let ahead = tied.filter { $0.index >= current }.min { $0.index < $1.index }
        return (ahead ?? tied.max { $0.index < $1.index })?.qid
    }
}

/// The one shared role rule for the guide, codebook and Auto passes: split
/// merged turns at question marks, drop mic-leg echoes of the room, and give
/// each turn a role hint. Pure: no state, no LLM call.
public enum TurnRoles {
    public struct Context: Sendable {
        public var matcher: GuideMatcher?
        /// Speaker IDs the user assigned to the moderator seat.
        public var moderatorSpeakers: Set<String>

        public init(matcher: GuideMatcher? = nil, moderatorSpeakers: Set<String> = []) {
            self.matcher = matcher
            self.moderatorSpeakers = moderatorSpeakers
        }
    }

    /// One settled turn as the echo check reads it.
    public struct Spoken: Sendable {
        public let id: String
        public let speaker: String
        public let startMs: Int
        public let endMs: Int
        public let text: String

        public init(id: String, speaker: String, startMs: Int, endMs: Int, text: String) {
            self.id = id
            self.speaker = speaker
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }
    }

    public static func role(speaker: String, text: String, context: Context) -> SpeechRole {
        if SpeakerEvidence.leg(for: speaker) == "Me" || context.moderatorSpeakers.contains(speaker) {
            return .moderator
        }
        if isBackchannel(text) {
            return .unknown
        }
        if isQuestionShaped(text) || isRestatement(text) || context.matcher?.matches(text) == true {
            return .moderator
        }
        return .respondent
    }

    private static let closers: Set<Character> = ["。", "！", "!", ".", "…", "~", "～", "\"", "”", "」", "』", ")", "）", " "]
    private static let questionMarks: Set<Character> = ["？", "?"]

    /// Ends in a question mark, or in 吗 before closing punctuation. 呢
    /// counts only before a question mark (that mark alone decides): a
    /// statement such as 我还没试过呢。 or 挺好的呢。 is a respondent's.
    public static func isQuestionShaped(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, closers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return questionMarks.contains(last) || last == "吗"
    }

    private static let restatementOpeners = ["所以", "好的", "那么", "那", "ok", "okay", "so "]
    private static let confirmations = ["对吧", "是吧", "对不对", "是不是", "right?", "right？"]
    private static let tallyWords = ["举手", "举个手", "raise your hand", "show of hands", "hands up"]

    /// A moderator's restating summary (所以…对吧) or a show-of-hands call.
    public static func isRestatement(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tallyWords.contains(where: lower.contains) {
            return true
        }
        return restatementOpeners.contains(where: lower.hasPrefix) && confirmations.contains(where: lower.contains)
    }

    private static let backchannelCharacters = Set("对嗯好是的啊呀哦呃哈行没错")
    private static let backchannelWords: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "right", "mm", "mhm", "sure"]

    /// A bare 对 or 嗯 is never evidence for what someone else said.
    public static func isBackchannel(_ text: String) -> Bool {
        let letters = normalized(text)
        guard !letters.isEmpty else { return true }
        if letters.count <= 4, letters.allSatisfy(backchannelCharacters.contains) {
            return true
        }
        return backchannelWords.contains(letters)
    }

    /// Split after each question mark that has more words after it, so a
    /// question and the answer merged into one system-leg turn become two.
    /// `offset` is each piece's character offset in the original text.
    public static func splitAtQuestions(_ text: String) -> [(text: String, offset: Int)] {
        let characters = Array(text)
        var pieces: [(text: String, offset: Int)] = []
        var start = 0
        var index = 0
        while index < characters.count {
            if questionMarks.contains(characters[index]) {
                var end = index + 1
                while end < characters.count, closers.contains(characters[end]) || questionMarks.contains(characters[end]) {
                    end += 1
                }
                let rest = String(characters[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty, !normalized(rest).isEmpty {
                    let piece = String(characters[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty {
                        pieces.append((piece, start))
                    }
                    start = end
                }
                index = end
            } else {
                index += 1
            }
        }
        let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            let leading = characters[start...].prefix { $0.isWhitespace }.count
            pieces.append((tail, start + leading))
        }
        return pieces.isEmpty ? [(text, 0)] : pieces
    }

    /// Mic-leg turns that only repeat the room. When the user listens to an
    /// in-room group on a speaker, the mic hears the same words the system
    /// leg carries, at the same time. Three tests must all hold:
    /// - the session shows the room on both legs (`roomOnBothLegs`, read on
    ///   `roomSample`, else on `all`): on a remote call the mic carries the
    ///   moderator's own questions, so this gate drops nothing;
    /// - the mic turn overlaps system-leg speech for at least half its length
    ///   (a moderator's follow-up comes after the answer, not over it);
    /// - at least `echoShare` of its unit pairs (`echoPairs`: word pairs in
    ///   English, character pairs in Chinese) occur in that overlapping speech.
    public static func micEchoIDs(_ candidates: [Spoken], against all: [Spoken], roomSample: [Spoken]? = nil) -> Set<String> {
        let system = all.filter { SpeakerEvidence.leg(for: $0.speaker) == "Them" }
        guard !system.isEmpty, candidates.contains(where: { SpeakerEvidence.leg(for: $0.speaker) == "Me" }) else { return [] }
        var pairs = EchoPairCache()
        guard roomOnBothLegs(roomSample ?? all, pairs: &pairs) else { return [] }
        return Set(candidates.filter { isEcho($0, system: system, pairs: &pairs) }.map(\.id))
    }

    /// The room reaches both legs: in `sample`, at least `roomEchoMinimum`
    /// mic turns, and at least half of the mic turns long enough to test,
    /// are echoes. A remote IDI or client call never meets this.
    public static func roomOnBothLegs(_ sample: [Spoken]) -> Bool {
        var pairs = EchoPairCache()
        return roomOnBothLegs(sample, pairs: &pairs)
    }

    private static func roomOnBothLegs(_ sample: [Spoken], pairs: inout EchoPairCache) -> Bool {
        let system = sample.filter { SpeakerEvidence.leg(for: $0.speaker) == "Them" }
        let mic = sample.filter { SpeakerEvidence.leg(for: $0.speaker) == "Me" && pairs.of($0).count >= echoMinimumPairs }
        guard !system.isEmpty, mic.count >= roomEchoMinimum else { return false }
        let echoes = mic.filter { isEcho($0, system: system, pairs: &pairs) }.count
        return echoes >= roomEchoMinimum && echoes * 2 >= mic.count
    }

    /// Each turn's unit pairs, built once per check: one check reads a
    /// system turn's pairs for every mic turn it overlaps, and the room
    /// test and the candidate test read the same turns.
    private struct EchoPairCache {
        private var byID: [String: Set<String>] = [:]

        mutating func of(_ turn: Spoken) -> Set<String> {
            if let known = byID[turn.id] {
                return known
            }
            let pairs = echoPairs(turn.text)
            byID[turn.id] = pairs
            return pairs
        }
    }

    private static func isEcho(_ turn: Spoken, system: [Spoken], pairs cache: inout EchoPairCache) -> Bool {
        guard SpeakerEvidence.leg(for: turn.speaker) == "Me" else { return false }
        let pairs = cache.of(turn)
        guard pairs.count >= echoMinimumPairs else { return false }
        let overlapping = system.filter { min($0.endMs, turn.endMs) - max($0.startMs, turn.startMs) > 0 }
        let overlapMs = overlapping.reduce(0) { $0 + min($1.endMs, turn.endMs) - max($1.startMs, turn.startMs) }
        guard !overlapping.isEmpty, overlapMs * 2 >= max(1, turn.endMs - turn.startMs) else { return false }
        var heard = Set<String>()
        for other in overlapping {
            heard.formUnion(cache.of(other))
        }
        return Double(pairs.intersection(heard).count) / Double(pairs.count) >= echoShare
    }

    static let echoShare = 0.8
    static let echoMinimumPairs = 4
    static let roomEchoMinimum = 3

    /// Adjacent pairs of echo units: a Chinese, Japanese or Korean character
    /// is one unit, a Latin word or a number is one unit. Character pairs in
    /// English repeat too often to tell an echo from a restated question.
    public static func echoPairs(_ text: String) -> Set<String> {
        var units: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if isCJK(character) {
                    if !word.isEmpty {
                        units.append(word)
                        word = ""
                    }
                    units.append(String(character))
                } else {
                    word.append(character)
                }
            } else if !word.isEmpty, character != "'", character != "’" {
                units.append(word)
                word = ""
            }
        }
        if !word.isEmpty {
            units.append(word)
        }
        guard units.count >= 2 else { return [] }
        return Set((0 ..< units.count - 1).map { units[$0] + " " + units[$0 + 1] })
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || (0x3040 ... 0x30FF).contains(scalar.value) || (0xAC00 ... 0xD7AF).contains(scalar.value)
        }
    }

    /// Lowercased letters and digits only: no spaces or punctuation.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Character n-grams as numbers: a role check runs on every line of
    /// every Auto window, and folding four Unicode scalars into one integer
    /// is far cheaper than building a string for each gram (2026-11-13
    /// endurance replay). A collision only nudges one Dice score.
    static func grams(_ text: String, size: Int) -> Set<UInt64> {
        let scalars = normalized(text).unicodeScalars.map { UInt64($0.value) }
        guard scalars.count >= size else { return [] }
        var result: Set<UInt64> = []
        result.reserveCapacity(scalars.count - size + 1)
        for start in 0 ... (scalars.count - size) {
            var key: UInt64 = 0
            for offset in 0 ..< size {
                key = key &* 0x1_0000_01B3 &+ scalars[start + offset]
            }
            result.insert(key)
        }
        return result
    }
}
