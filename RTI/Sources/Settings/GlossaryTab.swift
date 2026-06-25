import SwiftUI

// MARK: - Glossary

struct GlossaryTab: View {
    @Bindable private var store = GlossaryStore.shared

    var body: some View {
        SettingsPage(maxWidth: 760) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("How Glossary Terms Are Used", detail: "Names, acronyms, and domain terms are sent as a system instruction before every chat, summary, and recall call.") {
                    Text("Use this for proper names, client-specific jargon, and in-house spellings that the model should preserve exactly.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard("Entries", detail: "One entry per line: `Term — meaning`. Separators can be em dash, colon, or hyphen. Lines starting with `#` are ignored as section headers.") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $store.rawText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 260)
                            .settingsEditorBorder()
                            .overlay(alignment: .topLeading) {
                                if store.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Add terms here — one per line:\nTerm — meaning\n# Section header")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }

                        let count = store.entries.count
                        if count == 0 {
                            SettingsStatusLabel(text: "No entries parsed yet. The glossary is not currently sent to the model.", systemImage: "info.circle", color: .secondary)
                        } else {
                            SettingsStatusLabel(text: "\(count) entr\(count == 1 ? "y" : "ies") parsed and sent with every LLM call.", systemImage: "checkmark.circle.fill", color: .green)
                        }
                    }
                }

                SettingsCard("Example Format") {
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
                    .textSelection(.enabled)
                }
            }
        }
    }
}
