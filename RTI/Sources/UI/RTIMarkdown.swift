import SwiftUI
import MarkdownUI

/// Renders LLM-produced markdown with full block support (headings, lists,
/// code blocks, tables, blockquotes) themed for the overlay's dark
/// translucent panel (`MinimalAskComposer`'s answer stream).
struct RTIMarkdown: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(.rtiOverlay)
            .textSelection(.enabled)
    }
}

@MainActor
private extension Theme {
    static let rtiOverlay: Theme = Theme()
        .text {
            ForegroundColor(Color.overlayInk.opacity(0.92))
            FontSize(13.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(Color.overlayInk.opacity(0.10))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Color(red: 0.55, green: 0.78, blue: 1.0)) }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 12, bottom: 5)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14.5)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13.5)
                    ForegroundColor(Color.overlayInk)
                }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.24))
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
                        FontSize(12.5)
                        ForegroundColor(Color.overlayInk.opacity(0.95))
                    }
                    .padding(10)
            }
            .background(Color.overlayInk.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.overlayInk.opacity(0.35))
                        .frame(width: 2)
                }
                .foregroundStyle(Color.overlayInk.opacity(0.75))
        }
        .table { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(.horizontalBorders, color: Color.overlayInk.opacity(0.14)))
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
