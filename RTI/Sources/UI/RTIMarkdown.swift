import SwiftUI
import MarkdownUI

/// Renders LLM-produced markdown with full block support (headings, lists,
/// code blocks, tables, blockquotes) themed to match RTI's design system.
///
/// Two contexts:
///   - `.overlay` — dark translucent panel, white text (AssistantInputView,
///     ResponseView and overlay surfaces).
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
            FontSize(House.TypeToken.Size.body)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(RTIDesign.Color.chipFill)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(RTIDesign.Color.accentText) }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.title)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.heading)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.body)
                }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .em(0.22))
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(House.TypeToken.Size.code)
                        ForegroundColor(RTIDesign.Color.textPrimary)
                    }
                    .padding(10)
            }
            .background(RTIDesign.Color.well)
            .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm, style: .continuous))
            .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(RTIDesign.Color.textTertiary)
                        .frame(width: 2)
                }
                .foregroundStyle(RTIDesign.Color.textSecondary)
        }
        .table { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(.horizontalBorders, color: RTIDesign.Color.divider))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.clear)
                    )
            }
            .markdownMargin(top: 8, bottom: 14)
        }
        .tableCell { config in
            config.label
                .markdownTextStyle {
                    if config.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.22))
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
        }
        .thematicBreak {
            Color.clear
                .frame(height: 8)
                .markdownMargin(top: 0, bottom: 0)
        }

    static let rtiOverlay: Theme = Theme()
        .text {
            ForegroundColor(Color.overlayInk)
            FontSize(House.TypeToken.Size.body)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(RTIDesign.Color.chipFill)
        }
        .strong { FontWeight(.semibold) }
        // Links are the one place the accent is allowed (DESIGN.md).
        .link { ForegroundColor(RTIDesign.Color.accent) }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.heading)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 12, bottom: 5)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.body)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(House.TypeToken.Size.bodySmall)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(House.TypeToken.LineHeight.body - 1))
                .markdownMargin(top: 0, bottom: 9)
        }
        .listItem { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .em(0.22))
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(House.TypeToken.Size.code)
                        ForegroundColor(Color.overlayInk)
                    }
                    .padding(RTIDesign.Spacing.sm)
            }
            .background(RTIDesign.Color.well)
            .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm, style: .continuous))
            .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(RTIDesign.Color.border)
                        .frame(width: 2)
                }
                .foregroundStyle(Color.overlayInkSecondary)
        }
        .table { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(.horizontalBorders, color: RTIDesign.Color.divider))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.clear)
                    )
            }
            .markdownMargin(top: 8, bottom: 14)
        }
        .tableCell { config in
            config.label
                .markdownTextStyle {
                    if config.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.22))
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
        }
        .thematicBreak {
            Color.clear
                .frame(height: 8)
                .markdownMargin(top: 0, bottom: 0)
        }
}
