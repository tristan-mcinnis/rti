import SwiftUI
import MarkdownUI

/// Renders LLM-produced markdown with full block support (headings, lists,
/// code blocks, tables, blockquotes) themed to match RTI's design system.
///
/// Two contexts:
///   - `.overlay` — dark translucent panel, white text (AssistantInputView,
///     ResponseView, floating panels).
///   - `.panel`   — light Sessions UI, RTIDesign foreground colors.
struct RTIMarkdown: View {
    enum Style { case overlay, panel }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .panel) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(style == .overlay ? .rtiOverlay : .rtiPanel)
            .textSelection(.enabled)
    }
}

@MainActor
private extension Theme {
    static let rtiPanel: Theme = Theme()
        .text {
            ForegroundColor(RTIDesign.Color.textPrimary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(RTIDesign.Color.trackBackground)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(RTIDesign.Color.accentText) }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(20)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { config in
            config.label
                .lineSpacing(3)
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { config in
            config.label.markdownMargin(top: 2, bottom: 2)
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12.5)
                        ForegroundColor(RTIDesign.Color.textPrimary)
                    }
                    .padding(10)
            }
            .background(RTIDesign.Color.trackBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(RTIDesign.Color.accent.opacity(0.6))
                        .frame(width: 2)
                }
                .foregroundStyle(RTIDesign.Color.textSecondary)
        }
        .table { config in
            config.label
                .markdownTableBorderStyle(.init(color: RTIDesign.Color.border))
        }

    static let rtiOverlay: Theme = Theme()
        .text {
            ForegroundColor(.white.opacity(0.92))
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.white.opacity(0.10))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Color(red: 0.55, green: 0.78, blue: 1.0)) }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(18)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                    ForegroundColor(.white)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .paragraph { config in
            config.label
                .lineSpacing(2)
                .markdownMargin(top: 0, bottom: 6)
        }
        .listItem { config in
            config.label.markdownMargin(top: 2, bottom: 2)
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12.5)
                        ForegroundColor(.white.opacity(0.95))
                    }
                    .padding(10)
            }
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 2)
                }
                .foregroundStyle(.white.opacity(0.75))
        }
}
