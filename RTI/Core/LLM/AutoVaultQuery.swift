import Foundation

/// The vault query for one Auto pass. Auto searches the picked project for
/// what was just said, up to about once a minute. The raw window made a long,
/// noisy query; this keeps the few terms that say what the talk is about.
///
/// - A window with fewer than `minimumWords` words gets no search: there is
///   not enough talk to name a topic.
/// - Otherwise the query is the `maximumTerms` most salient distinct terms:
///   the most repeated first, then the longer word, then the earlier word.
///   Filler words and short numbers never count. In Chinese, filler bigrams
///   (然后, 一个), bigrams that hold a particle or pronoun (我们, 就是, or a
///   cross-word pair such as 个就) and cross-word pairs beside a filler
///   bigram (后价 in 然后价格) never count either.
public enum AutoVaultQuery {
    public static let maximumTerms = 12
    public static let minimumWords = 25

    /// The query for `spokenText`, or nil when the window is too short or
    /// holds no useful term.
    public static func query(
        from spokenText: String,
        maximumTerms: Int = maximumTerms,
        minimumWords: Int = minimumWords
    ) -> String? {
        guard wordCount(spokenText) >= minimumWords else { return nil }
        let terms = salientTerms(in: spokenText, limit: maximumTerms)
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    /// Up to `limit` distinct search terms, most salient first.
    public static func salientTerms(in text: String, limit: Int = maximumTerms) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        let tokens = VaultSearch.rawTokens(text)
        for (index, token) in tokens.enumerated() where isUseful(token) && !bridgesFiller(tokens, at: index) {
            counts[token, default: 0] += 1
            if firstSeen[token] == nil {
                firstSeen[token] = index
            }
        }
        let ranked = counts.keys.sorted { lhs, rhs in
            let lhsCount = counts[lhs] ?? 0
            let rhsCount = counts[rhs] ?? 0
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    /// Words in the window: each Latin or number run is one word, and every
    /// two CJK characters count as one word (Chinese has no spaces).
    public static func wordCount(_ text: String) -> Int {
        var words = 0
        var cjk = 0
        var inRun = false
        for character in text {
            if character.isCJK {
                cjk += 1
                inRun = false
            } else if character.isLetter || character.isNumber {
                if !inRun {
                    words += 1
                }
                inRun = true
            } else {
                inRun = false
            }
        }
        return words + (cjk + 1) / 2
    }

    /// True for a CJK bigram that shares a character with a filler bigram
    /// beside it: the pair crosses a word boundary (一个包装 gives 个包,
    /// 然后价格 gives 后价). The cost: 一个人 also drops 个人.
    private static func bridgesFiller(_ tokens: [String], at index: Int) -> Bool {
        let token = tokens[index]
        guard token.count == 2, token.allSatisfy(\.isCJK) else {
            return false
        }
        if index > 0 {
            let previous = tokens[index - 1]
            if cjkFillers.contains(previous), previous.last == token.first {
                return true
            }
        }
        if index + 1 < tokens.count {
            let next = tokens[index + 1]
            if cjkFillers.contains(next), token.last == next.first {
                return true
            }
        }
        return false
    }

    private static func isUseful(_ token: String) -> Bool {
        if fillers.contains(token) {
            return false
        }
        if token.contains(where: \.isCJK) {
            if cjkFillers.contains(token) || token.contains(where: cjkFunctionCharacters.contains) {
                return false
            }
        }
        // A year or a model number may matter; "12" or "30" rarely does.
        if token.allSatisfy(\.isNumber), token.count < 4 {
            return false
        }
        return true
    }

    /// Words that fill speech but never name a topic. Lower case, as
    /// `VaultSearch.rawTokens` emits them.
    private static let fillers: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "back", "be", "because", "been", "but", "by", "can", "could", "did", "do", "does", "doing",
        "don", "done", "even", "for", "from", "get", "give", "go", "going", "gonna", "good", "got",
        "had", "has", "have", "he", "her", "here", "him", "his", "how", "if", "in", "into", "is",
        "it", "its", "just", "kind", "know", "let", "like", "ll", "look", "lot", "make", "maybe",
        "me", "mean", "more", "much", "my", "no", "not", "now", "of", "oh", "ok", "okay", "on",
        "one", "or", "our", "out", "over", "really", "right", "said", "say", "see", "she", "so",
        "some", "something", "sort", "still", "sure", "tell", "than", "thank", "thanks", "that",
        "the", "their", "them", "then", "there", "these", "they", "thing", "things", "think",
        "this", "those", "through", "to", "too", "uh", "um", "up", "us", "very", "want", "was",
        "way", "we", "well", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "would", "yeah", "yes", "you", "your", "ve", "re",
    ]

    /// Particles, pronouns and demonstratives. A bigram that holds one is a
    /// function word (我们, 这个) or crosses a word boundary (个就), so it
    /// never names a topic. Characters that also start or end topic words
    /// (在线, 成都, 功能, 会员) are not in this set.
    private static let cjkFunctionCharacters: Set<Character> = [
        "的", "了", "吗", "呢", "吧", "啊", "嗯", "哦", "呀", "哈", "嘛", "我", "你", "您", "他", "她",
        "它", "们", "这", "那", "哪", "就", "也", "是", "很", "么",
    ]

    /// Chinese filler bigrams that hold no function character.
    /// `VaultSearch.rawTokens` emits CJK text as overlapping bigrams.
    private static let cjkFillers: Set<String> = [
        "一个", "这个", "那个", "一些", "一下", "一点", "一样", "一直", "一般", "一定", "然后", "之后", "以后", "之前",
        "以前", "什么", "怎么", "为什", "多少", "还有", "没有", "不会", "不过", "但是", "可是",
        "而且", "因为", "所以", "如果", "觉得", "知道", "应该", "可能", "可以", "其实", "现在", "正在",
        "时候", "已经", "东西", "感觉", "比较", "非常", "特别", "不错", "对对", "自己", "大家", "有点",
        "有些", "之类", "所谓", "而已", "怎样", "比如", "然而",
        "当然", "包括", "关于", "或者", "以及", "还要", "需要", "谢谢", "好好",
    ]
}
