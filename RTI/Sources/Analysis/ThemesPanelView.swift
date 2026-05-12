import SwiftUI

struct ThemesPanelView: View {
    private let controller = ThemesController.shared

    var body: some View {
        FloatingPanelChrome(
            title: "Themes",
            opacityKey: themesOpacityKey,
            defaultOpacity: themesDefaultOpacity,
            panelID: .themes,
            titleAccessory: {
                if controller.isHiFi {
                    Text("Final")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.35)))
                }
                if controller.isGenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            },
            headerActions: {
                PanelHeaderEllipsisMenu(panelID: .themes) {
                    Button("Copy all", action: copyAll)
                        .disabled(controller.payload.themes.isEmpty)
                    Button("Export as .md…", action: exportToFile)
                        .disabled(controller.payload.themes.isEmpty)
                    Divider()
                    Button("Regenerate now", action: regenerate)
                        .disabled(controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                    Button("Clear", role: .destructive) { controller.clear() }
                        .disabled(controller.payload.themes.isEmpty)
                }
            }
        ) {
            VStack(spacing: 0) {
                if let error = controller.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                if controller.payload.themes.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.stack.badge.minus")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Waiting for first themes pass…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Themes regenerate every couple of minutes while recording.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.payload.themes) { theme in
                                ThemeCard(theme: theme)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private func combinedMarkdown() -> String {
        ThemesMarkdownFormatter.format(controller.payload, isHiFi: controller.isHiFi)
    }

    private func copyAll() {
        NSPasteboard.copyMarkdownRich(combinedMarkdown())
    }

    private func regenerate() {
        guard let sid = SessionCoordinator.shared.currentSessionId else { return }
        Task { _ = await controller.generate(sessionId: sid) }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-themes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct ThemeCard: View {
    let theme: ThemeGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.copyMarkdownRich(ThemesMarkdownFormatter.formatGroup(theme))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy this theme")
            }

            if let summary = theme.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(theme.quotes) { quote in
                    QuoteRow(quote: quote)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct QuoteRow: View {
    let quote: ThemeQuote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let speaker = quote.speaker, !speaker.isEmpty {
                        Text(speaker)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    if !quote.formattedTimestamp.isEmpty {
                        Text(quote.formattedTimestamp)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                }
                Text(quote.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// Pure formatter — also used by the corpus markdown writer on
/// session end so the final hi-fi themes pass lands in the .md file.
enum ThemesMarkdownFormatter {
    static func format(_ payload: ThemesPayload, isHiFi: Bool) -> String {
        var lines: [String] = []
        let title = isHiFi ? "## Themes (final)" : "## Themes"
        lines.append(title)
        lines.append("")
        for theme in payload.themes {
            lines.append(formatGroup(theme))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func formatGroup(_ group: ThemeGroup) -> String {
        var lines: [String] = []
        lines.append("### \(group.title)")
        if let summary = group.summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        for quote in group.quotes {
            let stamp = quote.formattedTimestamp.isEmpty ? "" : " (\(quote.formattedTimestamp))"
            let speaker = quote.speaker.map { "**\($0)**" + stamp + ": " } ?? ""
            lines.append("> \(speaker)\(quote.text)")
        }
        return lines.joined(separator: "\n")
    }
}
