import SwiftUI

extension SessionDetailView {
    // MARK: - Section rendering

    /// Single rendering path for "title + markdown body" used by all summary
    /// sections. Pre-parses bullet lines so they show as proper bullets with
    /// hanging indent rather than literal `-` characters.
    func sectionBlock(title: String, content: String, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
            SectionHeader(title)
            sectionBody(content)
        }
    }

    func sectionBlockOptional(title: String, content: String?) -> some View {
        Group {
            if let raw = content, !isContentEmpty(raw) {
                sectionBlock(title: title, content: raw, isFirst: false)
            }
        }
    }

    func isContentEmpty(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || normalized == "none" || normalized == "none."
    }

    /// Render markdown body as either a bulleted list (when most lines start
    /// with `-` or `*`) or a flowing paragraph (with inline markdown).
    @ViewBuilder
    func sectionBody(_ raw: String) -> some View {
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bulletLines = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        let isList = !lines.isEmpty && bulletLines.count >= max(1, lines.count - 1)

        if isList {
            VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.xs)) {
                ForEach(Array(bulletLines.enumerated()), id: \.offset) { _, line in
                    let stripped = String(line.dropFirst(2))
                    HStack(alignment: .top, spacing: RTIDesign.Spacing.sm) {
                        Text("•")
                            .font(RTIDesign.Font.body)
                            .foregroundStyle(RTIDesign.Color.accentText)
                            .frame(width: 12, alignment: .leading)
                        Text(attributed(stripped))
                            .font(RTIDesign.Font.body)
                            .foregroundStyle(RTIDesign.Color.textPrimary)
                            .lineSpacing(density.scaled(4))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text(attributed(raw))
                .font(RTIDesign.Font.body)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(density.scaled(4))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    struct FollowUpSection: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    func splitFollowUps(_ raw: String) -> [FollowUpSection] {
        let lines = raw.components(separatedBy: "\n")
        var sections: [FollowUpSection] = []
        var currentTitle: String?
        var currentBody: [String] = []
        func flush() {
            if let title = currentTitle {
                let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(FollowUpSection(title: title, body: body))
            }
            currentTitle = nil
            currentBody = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }

    func extractSummarySection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        // Locate the start: skip past an optional "## Summary" opener.
        let contentStart: Int
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Summary" }) {
            contentStart = i + 1
        } else {
            contentStart = 0
        }
        // Always cut at the next "## " heading so the lead paragraph
        // never contains raw markdown for the structured sections
        // (those render in their own blocks below).
        guard contentStart < lines.count else { return "" }
        guard let end = lines[contentStart...].firstIndex(where: { $0.hasPrefix("## ") }) else {
            return lines[contentStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[contentStart..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
