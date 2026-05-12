import SwiftUI

// MARK: - Glossary

struct GlossaryTab: View {
    @Bindable private var store = GlossaryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Glossary")
                .font(.headline)
            Text("Names, acronyms, and domain terms the assistant should use **exactly as written**. RTI sends these to the model as a system instruction before every chat, summary, and recall call — so the LLM picks up jargon, proper names, and your in-house spellings instead of guessing from context.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Format: one entry per line — `Term — meaning`. Separator can be em-dash (`—`), colon (`:`), or hyphen (`-`). Lines starting with `#` are ignored (use them as section headers). Caps at 200 entries so the prompt stays bounded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Examples")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("""
            # People
            Alec — head of design (often misheard as "Alex")
            Jane — Acme marketing lead

            # Projects
            NSW — Acme Sportswear zone
            ICP — Ideal Customer Profile
            """)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06))
                )

            TextEditor(text: $store.rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            let count = store.entries.count
            Text(count == 0 ? "No entries parsed yet — the glossary is not currently sent to the model." : "\(count) entr\(count == 1 ? "y" : "ies") parsed. Sent as a system instruction with every LLM call.")
                .font(.caption)
                .foregroundStyle(count == 0 ? Color.secondary : Color.green)
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}
