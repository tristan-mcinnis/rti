import Foundation

/// User-selected language takes precedence over the live default. Only an
/// explicit continuing preference from this thread outlives a single request.
public enum LiveReplyLanguage {
    public static func instructions(history: [ChatEntry]) -> String {
        var rule = """
        Live reply language: default to a self-contained English answer. Put ALL English takeaways first. Chinese source material, earlier assistant output or a question typed in Chinese does not change that default. An explicit user instruction about reply language or format, including in an edited action prompt, takes precedence. A one-turn request expires after that reply.
        After the English, put each needed annotation in a separate Markdown paragraph. Label exact original speech **Source [time, speaker]**, using only supplied timestamps and confidence-safe labels. Preserve embedded English and original punctuation. Label drafted words **Suggested question for the moderator** or **Suggested reply for the user**. For a Mandarin source or a Mandarin line to speak, put **Pinyin** on a separate line with tone marks; preserve neutral tones and Latin names. Mark uncertain readings, dialects and proper names when needed. Do not invent Chinese or pinyin for English-only material. Keep quotations, suggestions and pronunciation separate.
        """
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
