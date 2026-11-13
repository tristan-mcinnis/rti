import Foundation

/// The meeting language as Auto reads it from the words, and the pinyin the
/// rail can show under a Mandarin line. Pure.
public enum AutoCardLanguage {
    /// Above this share of CJK characters a window is a Mandarin window: a
    /// SAY or ASK card without a Mandarin line is dropped.
    public static let mandarinShare = 0.3

    /// The share of CJK characters among letters and CJK characters. Digits,
    /// punctuation and spaces do not count. 0 for a text with neither.
    public static func cjkShare(_ text: String) -> Double {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if scalar.properties.isAlphabetic {
                latin += 1
            }
        }
        let total = cjk + latin
        return total == 0 ? 0 : Double(cjk) / Double(total)
    }

    public static func isMandarin(_ text: String) -> Bool {
        cjkShare(text) > mandarinShare
    }

    /// The English line and the Mandarin line of one card, from the model's
    /// `text_en` and `text_zh`. Pure.
    /// - With a Mandarin line and no English one, the Mandarin line is both.
    /// - With no Mandarin line, an English field that is itself Mandarin
    ///   (the model put the line in the wrong field) is both.
    /// - With no Mandarin line, an older saved prompt's one `text` that holds
    ///   an English line, a Mandarin line and a pinyin line on separate lines
    ///   splits: the Mandarin lines become the Mandarin line, the pinyin line
    ///   is dropped (this Mac makes its own), the rest is the English line.
    public static func lines(english: String, mandarin: String?) -> (text: String, textZH: String?) {
        let english = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let mandarin = mandarin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mandarin, !mandarin.isEmpty {
            return (english.isEmpty ? mandarin : english, mandarin)
        }
        guard english.unicodeScalars.contains(where: isCJK) else { return (english, nil) }
        let parts = english.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let chinese = parts.filter(isMandarin)
        let latin = parts.filter { !isMandarin($0) && !isPinyin($0) }
        if !chinese.isEmpty, !latin.isEmpty {
            return (latin.joined(separator: " "), chinese.joined(separator: " "))
        }
        if !chinese.isEmpty {
            let line = chinese.joined(separator: " ")
            return (line, line)
        }
        return (english, nil)
    }

    /// A Latin line with a tone-marked vowel and no other letters outside
    /// pinyin's: the reading aid an older prompt asked the model to write.
    static func isPinyin(_ line: String) -> Bool {
        let marked = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ"
        guard line.contains(where: { marked.contains($0) }) else { return false }
        return !line.unicodeScalars.contains(where: isCJK)
    }

    /// Tone-marked pinyin from the system transform, computed once per card.
    /// nil for a line with no Han characters. A word with two readings may
    /// get the wrong one; it is a reading aid, not the line itself.
    public static func pinyin(_ text: String?) -> String? {
        guard let text, text.unicodeScalars.contains(where: isCJK),
              let latin = text.applyingTransform(.mandarinToLatin, reverse: false)
        else { return nil }
        let spaced = latin.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return spaced.isEmpty ? nil : spaced
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FA1F:
            true
        default:
            false
        }
    }
}

/// What a research Auto pass is for: a group (three or more voices), an
/// interview, or not known. It sets the pass floor and how much new
/// respondent talk a pass needs.
public enum ResearchFormat: String, Sendable {
    case group
    case interview
    case unknown

    /// From the session roster (respondent seats) and the guide title. Two or
    /// more seats, with the moderator, make three or more voices.
    public static func infer(rosterCount: Int, guideTitle: String?) -> ResearchFormat {
        if rosterCount >= 2 {
            return .group
        }
        if rosterCount == 1 {
            return .interview
        }
        let title = (guideTitle ?? "").lowercased()
        if ["fgd", "focus group", "group discussion", "group interview", "座谈", "小组"].contains(where: title.contains) {
            return .group
        }
        // "idi" only as a whole word: "acidity" or "validity" is no interview.
        let words = Set(title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if words.contains("idi") || ["interview", "访谈", "深访"].contains(where: title.contains) {
            return .interview
        }
        return .unknown
    }

    /// New respondent characters a research pass needs before it runs.
    public var minimumRespondentCharacters: Int {
        self == .interview ? 40 : 150
    }
}

/// The code-side rules on what an Auto pass may show. The prompt asks for
/// the same things; these hold when the model does not.
public enum AutoCardRules {
    /// A card this close to one shown in the last `repeatWindow` is a repeat.
    public static let repeatLimit = 0.5
    public static let repeatWindow: TimeInterval = 15 * 60

    /// Words for Latin text and character pairs for CJK text, lowercased.
    /// A lone CJK character counts as one unit.
    public static func units(_ text: String) -> Set<String> {
        var units = Set<String>()
        var word = ""
        var run: [Character] = []
        func flushWord() {
            if !word.isEmpty {
                units.insert(word)
            }
            word = ""
        }
        func flushRun() {
            if run.count == 1 {
                units.insert(String(run[0]))
            } else if run.count > 1 {
                for index in 0 ..< run.count - 1 {
                    units.insert(String(run[index ... index + 1]))
                }
            }
            run = []
        }
        for character in text.lowercased() {
            if character.unicodeScalars.contains(where: AutoCardLanguage.isCJK) {
                flushWord()
                run.append(character)
            } else if character.isLetter || character.isNumber {
                flushRun()
                word.append(character)
            } else {
                flushWord()
                flushRun()
            }
        }
        flushWord()
        flushRun()
        return units
    }

    public static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = units(lhs)
        let right = units(rhs)
        let union = left.union(right).count
        return union == 0 ? 0 : Double(left.intersection(right).count) / Double(union)
    }

    /// The English lines, or the Mandarin lines, overlap by `repeatLimit` or more.
    public static func isRepeat(_ card: AutoAssistCard, of other: AutoAssistCard) -> Bool {
        if jaccard(card.text, other.text) >= repeatLimit {
            return true
        }
        if let zh = card.textZH, let otherZH = other.textZH, jaccard(zh, otherZH) >= repeatLimit {
            return true
        }
        return false
    }

    /// A FLAG that quotes two different call times (mm:ss) is a contradiction.
    public static func isContradiction(_ card: AutoAssistCard) -> Bool {
        guard card.kind == .flag else { return false }
        let text = card.text + " " + card.why
        let times = text.matches(of: /\b\d{1,2}:\d{2}(?::\d{2})?\b/).map { String($0.output) }
        return Set(times).count >= 2
    }

    /// A card that names a discussion guide. With no guide running, such a
    /// card is made up (the 2026-11-12 no-guide replay invented a skipped
    /// guide probe).
    public static func mentionsGuide(_ card: AutoAssistCard) -> Bool {
        let text = [card.text, card.textZH ?? "", card.why].joined(separator: " ")
        if text.contains(/(?i)\bguides?\b|\bguide's\b/) {
            return true
        }
        return ["指南", "提纲", "访纲", "大纲"].contains { text.contains($0) }
    }

    /// The cards a pass may offer the rail, in the model's order:
    /// - a RECALL must cite a document this pass supplied;
    /// - with no guide running, a card never names a guide;
    /// - in a Mandarin window a SAY or ASK needs its Mandarin line;
    /// - a card close to one in `recent` or earlier in the batch is a repeat;
    /// - a research pass keeps one card, plus contradictions.
    public static func accept(
        _ cards: [AutoAssistCard],
        callType: CallType,
        mandarin: Bool,
        recent: [AutoAssistCard],
        guideActive: Bool = true
    ) -> [AutoAssistCard] {
        var kept: [AutoAssistCard] = []
        for card in cards {
            if card.kind == .recall, card.citation == nil {
                continue
            }
            if !guideActive, mentionsGuide(card) {
                continue
            }
            if mandarin, card.kind == .say || card.kind == .ask, card.textZH == nil {
                continue
            }
            if (recent + kept).contains(where: { isRepeat(card, of: $0) }) {
                continue
            }
            if callType == .research, !kept.isEmpty, !isContradiction(card) {
                continue
            }
            kept.append(card)
        }
        return kept
    }
}

/// Facts a research Auto pass is given rather than asked to work out.
public enum AutoResearchSignals {
    /// No system-leg speech for this long, after some, is worth a FLAG.
    public static let silenceMs = 3 * 60 * 1000

    /// New respondent characters in these turns: letters and CJK characters
    /// of turns with the respondent role. `isThem` marks the system leg. A
    /// call with no system leg at all (a room heard only on the mic) reads
    /// the mic turns by their words alone.
    public static func respondentCharacters(
        _ turns: [(isThem: Bool, text: String)],
        sessionHasThem: Bool,
        context: TurnRoles.Context
    ) -> Int {
        turns.reduce(0) { total, turn in
            guard turn.isThem || !sessionHasThem, textRole(turn.text, context: context) == .respondent else { return total }
            return total + turn.text.unicodeScalars.filter { $0.properties.isAlphabetic || AutoCardLanguage.isCJK($0) }.count
        }
    }

    /// The role the words alone give a turn, as `TurnRoles.role` does for
    /// the system leg.
    static func textRole(_ text: String, context: TurnRoles.Context) -> SpeechRole {
        if TurnRoles.isBackchannel(text) {
            return .unknown
        }
        if TurnRoles.isQuestionShaped(text) || TurnRoles.isRestatement(text) || context.matcher?.matches(text) == true {
            return .moderator
        }
        return .respondent
    }

    /// "No Them speech for N min" when the other side has been silent for
    /// `silenceMs` or more while the call went on.
    public static func silence(lastThemMs: Int?, latestMs: Int?) -> String? {
        guard let lastThemMs, let latestMs, latestMs - lastThemMs >= silenceMs else { return nil }
        let minutes = (latestMs - lastThemMs) / 60000
        return "No Them speech for \(minutes) min (since \(TimeFormat.elapsedMs(lastThemMs))): the other side's audio may have dropped."
    }

    /// "S2 Daily routine: 22 of 15 min; open: S2Q3, S2Q4" once a section runs
    /// past its budget. nil within budget or with no budget.
    public static func overrun(
        section: GuideDocument.Section,
        elapsed: TimeInterval,
        openQIDs: [String]
    ) -> String? {
        guard let budget = section.minutes, budget > 0, elapsed > Double(budget * 60) else { return nil }
        let used = Int(elapsed / 60)
        let open = openQIDs.isEmpty ? "" : "; open questions at risk: " + openQIDs.joined(separator: ", ")
        return "Section \(section.id) \(section.title) has run \(used) min of its \(budget) min budget\(open)."
    }

    /// One stable line per section with a budget: "S1 Warm-up: 10 min".
    public static func budgets(_ guide: GuideDocument) -> [String] {
        guide.sections.compactMap { section in
            section.minutes.map { "\(section.id) \(section.title): \($0) min" }
        }
    }
}
