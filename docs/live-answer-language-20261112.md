# English-first live Assist

**Design for review · 12 November 2026 · RTI source `67c44ec8`**

Read the answer in English at a glance. Keep the original Mandarin and its pronunciation immediately below the English, where the moderator can read them aloud or check the evidence.

## Why the three languages run together

| Entry point | Instruction RTI sends today |
| --- | --- |
| Typed Ask or follow-up | The live call type supplies the system prompt. Research asks for short answers and exact original-language quotes; it supplies no default reply language. Earlier assistant messages keep their original wording in the next request. “Answer latest” adds a concise-answer instruction of its own. |
| Assist, Say next, Follow-ups | The speaker's Assist and Say next request words in the conversation's language. Both Follow-ups variants specifically request questions in that language with English in parentheses. Research enables listener framing; listener Assist requests exactly two lines and inserts original terms followed by pinyin and meaning. |
| Quick recap, all three Recap depths, Research actions | Recap appends one shared rule requiring English and inline `term (pinyin/romanization, English meaning)`. Key tensions, What's unsaid and Emerging themes have similar rules. The format that makes an English bullet hard to scan is explicitly requested. |

`PromptStore` resolves each editable leaf from Settings, falling back to its shipped text. During recording, the effective Client, Research, Internal or Personal prompt comes first. The listener suffix joins that system message when active. Meeting context, optional brief, glossary, screen and document context precede history. The last user message contains the transcript, user question or selected action, then general overlay-format instructions. The general formatter asks for short paragraphs and has no language-order rule. [Defaults and shipped wording](../RTI/Core/LLM/PromptID.swift) · [Call types](../RTI/Core/Calls/CallType.swift) · [Prompt overrides](../RTI/Sources/LLM/PromptStore.swift) · [Action dispatch](../RTI/Sources/LLM/LLMController+Actions.swift) · [Turn assembly](../RTI/Core/LLM/AssistantTurnBuilder.swift)

The Transcript target controls Soniox translation. The assistant's recent context takes original turns; changing the target does not select a reply language. Assist streams Markdown text into the chat, saves the answer in the thread and projects it into meeting chat exports. Current Assist has no separate pinyin generator or second rendering pass that unpacks an inline gloss. [Transcript input](../RTI/Sources/LLM/LLMController+Send.swift) · [Transcript translation](../RTI/Sources/UI/Overlay/TranscriptTabView.swift) · [Chat rendering](../RTI/Sources/UI/HouseChat/HouseThread.swift) · [Thread persistence](../RTI/Sources/LLM/LLMController+Threads.swift) · [Export](../RTI/Sources/Session/SessionArchive.swift)

## Proposed reply contract

1. Default to a self-contained English answer for live Ask, Assist, Answer latest, Recap and moderation actions. Put all English takeaways first. A Chinese transcript, pasted Chinese, or a follow-up typed in Chinese supplies context; an explicit instruction such as “answer in Chinese”, “English only” or “give just the Mandarin and pinyin” selects the requested format for that turn. Keep an explicit ongoing preference within its conversation.
2. Under the answer, pair only the useful Chinese with its tone-marked Mandarin pinyin. Give each its own visible Markdown paragraph. Label a cited turn **Source** with timestamp and confidence-safe speaker. Copy its exact original words including embedded English. Label newly drafted wording **Suggested question** and identify the intended speaker. A pronunciation or translation never enters the cited words.
3. Include a Mandarin rendering when the user needs a line to speak. For English-only material, include Chinese or pronunciation when requested or when the actual speaking situation requires it. Preserve neutral tones, existing Latin names and non-Mandarin text; if a name, polyphonic character or dialect reading cannot be established, retain the original and mark its pronunciation uncertain.
4. Apply the shared rule when assembling live Assist requests; replace conflicting inline-gloss defaults at their existing prompt IDs. Keep each action's evidence, scope and brevity requirements. Count evidence/pronunciation lines as annotations so they do not displace the English takeaways. Preserve explicit user prompt edits and surface changed defaults via Settings' existing review indicator. Standalone chat, live Notes, Auto card JSON and historical answers keep their existing contracts.

**Example from an invented turn**

They took the subway. The reason is still unclear.

**Suggested question for the moderator** What made you choose the subway that day?

**Source [02:10, Them]** “我坐地铁。”

**Pinyin** Wǒ zuò dìtiě.

**Suggested question in Mandarin** 那天为什么坐地铁？

**Pinyin** Nà tiān wèishénme zuò dìtiě?

## Verification

An offline test assembled Ask, Quick recap and Follow-ups from the production prompt composer and turn builder with an invented Mandarin quote, prior Chinese reply and English question. All preserved the source words. Quick recap contained the inline romanization rule; Follow-ups contained the English-in-parentheses instruction; the Research system prompt supplied neither a default language nor an English-first order. The probe and 15 existing catalogue/registry tests passed. This checks request contents; model compliance still needs a beta check.

For implementation, fixture-test English, Mandarin and mixed follow-ups; explicit per-turn and continuing overrides; all live call types, recap depths, typed Ask and action dispatch; pre-existing custom prompts; uncertain names; exact quote/time/speaker; and evidence versus drafted wording. Render a streamed and completed reply at narrow width, then compare copy, thread reload and chat export against the same Markdown. Verify that changing the Soniox target leaves the answer preference intact.
