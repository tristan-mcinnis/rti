import Foundation

/// User-selected language takes precedence over the live default. Only an
/// explicit continuing preference from this thread outlives a single request.
public enum LiveReplyLanguage {
    /// Recap actions that reply as a summary: their answer is the English
    /// bullets alone, with no Source and Pinyin blocks after them (2026-11-14:
    /// those blocks buried the takeaway during a live group).
    public static let summaryActions: Set<String> = ["Quick recap", "Recap"]
    /// Actions with a format of their own (questions, a card, an answer):
    /// the shared Source and suggestion blocks overrode it, so these get only
    /// pinyin under a Mandarin line to say (2026-11-15 eval).
    public static let compactActions: Set<String> = ["Follow-ups", "Assist", "Answer latest"]
    /// Write-ups in English prose with times, no quote blocks (2026-11-15:
    /// cited one-liners under long Source lines were not a theme read).
    public static let writeUpActions: Set<String> = ["Emerging themes", "Unprobed tension", "Said vs done", "Echo check"]

    public static func instructions(history: [ChatEntry], action: String? = nil) -> String {
        var rule = """
        Live reply language: default to a self-contained English answer. Put ALL English takeaways first. Chinese source material, earlier assistant output or a question typed in Chinese does not change that default. An explicit user instruction about reply language or format, including in an edited action prompt, takes precedence. A one-turn request expires after that reply.
        """
        if let action, summaryActions.contains(action) {
            rule += "\nThis is a summary: give only the English bullets. No Source blocks, quotes, timestamps or pinyin unless the user asks for them."
        } else if let action, writeUpActions.contains(action) {
            rule += "\nThis is a write-up: follow the action's own format exactly, in English. Give times as the action asks. No Source blocks or quoted Chinese lines unless the user asks; pinyin only under a Mandarin line the action asks for."
        } else if let action, compactActions.contains(action) {
            rule += "\nFollow the action's own format exactly. Add no Source blocks, notes, preamble or extra items. Under each Mandarin line meant to be said aloud, put one **Pinyin** line with tone marks; no pinyin without its Chinese line."
        } else {
            rule += "\n" + """
        After the English, put each needed annotation in a separate Markdown paragraph. Add a source only for a transcript line that directly supports the answer; when none does, add no source. Label exact original speech **Source [time, speaker]**, using only supplied timestamps and confidence-safe labels. Preserve embedded English and original punctuation. Add **Suggested question for the moderator** only for one question worth asking now, and **Suggested reply for the user** only when someone asked the user something they must answer aloud. For a Mandarin source or a Mandarin line to speak, put **Pinyin** on a separate line with tone marks; preserve neutral tones and Latin names. Mark uncertain readings, dialects and proper names when needed. Do not invent Chinese or pinyin for English-only material. Keep quotations, suggestions and pronunciation separate.
        """
        }
        rule += "\nBefore you say a user note conflicts with the transcript, look for the line that supports it. Contradict a note only when no line supports it, and quote both."
        // History is truncated for the model. Carry only the recognized language
        // setting across that boundary, never unrelated text from an old turn.
        for entry in history.reversed() where entry.role == "user" && (entry.action == "Ask" || entry.action == nil) {
            let text = entry.text.lowercased()
            guard ["from now on", "going forward", "for the rest of", "for this whole", "always answer", "always reply", "以后", "接下来都", "一直用"].contains(where: text.contains) else { continue }
            let format: String
            if text.contains("pinyin") || text.contains("拼音") {
                format = "Mandarin with pinyin"
            } else if ["english", "英文", "英语"].contains(where: text.contains) {
                format = "English"
            } else if ["chinese", "mandarin", "中文", "汉语"].contains(where: text.contains) {
                format = "Chinese"
            } else {
                continue
            }
            rule += "\nThe user's continuing reply-language preference in this chat is \(format). Apply a later explicit request for this turn first."
            break
        }
        return rule
    }
}
