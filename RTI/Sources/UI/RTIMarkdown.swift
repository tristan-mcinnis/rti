import SwiftUI
import MarkdownUI

/// Renders LLM-produced markdown with full block support (headings, lists,
/// code blocks, tables, blockquotes) themed to match RTI's design system.
///
/// Two contexts:
///   - `.overlay` — the Assist thread's answer prose (chat-surfaces.md
///     section 2): `body` at the text-size setting, line height 1.55, code
///     blocks with a header strip. `findMarks` turns on the find theme,
///     where `~~hit~~` and `[hit](rti-find:current)` draw as the hover and
///     selection fills (see `HouseFindBar.swift`).
///   - `.panel`   — light Sessions UI, RTIDesign foreground colors.
struct RTIMarkdown: View {
    enum Style { case overlay, panel }

    let text: String
    let style: Style
    /// Overlay only: the prose size (the text-size setting, 14 by default).
    var proseSize: CGFloat = House.TypeToken.Size.body
    /// Overlay only: draw find's hit markers as fills.
    var findMarks = false

    init(_ text: String, style: Style = .panel, proseSize: CGFloat = House.TypeToken.Size.body, findMarks: Bool = false) {
        self.text = text
        self.style = style
        self.proseSize = proseSize
        self.findMarks = findMarks
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(style == .overlay ? OverlayThemes.theme(size: proseSize, findMarks: findMarks) : .rtiPanel)
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
}

/// The overlay's answer themes, one per prose size and find state, built
/// once each.
@MainActor
private enum OverlayThemes {
    private static var cache: [String: Theme] = [:]

    static func theme(size: CGFloat, findMarks: Bool) -> Theme {
        let key = "\(size)-\(findMarks)"
        if let theme = cache[key] { return theme }
        let theme = make(size: size, findMarks: findMarks)
        cache[key] = theme
        return theme
    }

    /// A size relative to the prose, so headings and code follow the
    /// text-size setting.
    private static func em(_ tokenSize: CGFloat) -> RelativeSize {
        .em(tokenSize / House.TypeToken.Size.body)
    }

    private static func make(size: CGFloat, findMarks: Bool) -> Theme {
        // Leading that takes `body` to its 1.55 line height, as a fraction
        // of the size so it scales with the setting.
        let leading = RelativeSize.em(HouseChatType.proseLineSpacing / House.TypeToken.Size.body)
        var theme = Theme()
            .text {
                ForegroundColor(House.ColorToken.textPrimary)
                FontSize(size)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(em(House.TypeToken.Size.code))
                BackgroundColor(House.ColorToken.chipFill)
            }
            .strong { FontWeight(.semibold) }
            // Links are the one place the accent is allowed (DESIGN.md).
            .link { ForegroundColor(House.ColorToken.accent) }
            .heading1 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(em(House.TypeToken.Size.heading))
                        ForegroundColor(House.ColorToken.textPrimary)
                    }
                    .markdownMargin(top: House.Spacing.sm, bottom: House.Spacing.xxs)
            }
            .heading2 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(em(House.TypeToken.Size.body))
                        ForegroundColor(House.ColorToken.textPrimary)
                    }
                    .markdownMargin(top: House.Spacing.sm, bottom: House.Spacing.xxs)
            }
            .heading3 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(em(House.TypeToken.Size.bodySmall))
                        ForegroundColor(House.ColorToken.textPrimary)
                    }
                    .markdownMargin(top: House.Spacing.xs, bottom: House.Spacing.xxs)
            }
            .paragraph { config in
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(leading)
                    .markdownMargin(top: 0, bottom: House.Spacing.sm)
            }
            .listItem { config in
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: .em(House.Spacing.xxs / House.TypeToken.Size.body))
            }
            .codeBlock { config in
                OverlayCodeBlock(configuration: config)
                    .markdownMargin(top: House.Spacing.xxs, bottom: House.Spacing.sm)
            }
            .blockquote { config in
                config.label
                    .padding(.leading, House.Spacing.sm)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(House.ColorToken.stroke)
                            .frame(width: House.Spacing.xxs / 2)
                    }
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .table { config in
                ScrollView(.horizontal, showsIndicators: false) {
                    config.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTableBorderStyle(.init(.horizontalBorders, color: House.ColorToken.divider))
                        .markdownTableBackgroundStyle(
                            .alternatingRows(Color.clear, Color.clear)
                        )
                }
                .markdownMargin(top: House.Spacing.xs, bottom: House.Spacing.sm)
            }
            .tableCell { config in
                config.label
                    .markdownTextStyle {
                        if config.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(leading)
                    .padding(.vertical, House.Spacing.xs)
                    .padding(.horizontal, House.Spacing.sm)
            }
            .thematicBreak {
                HouseDivider()
                    .markdownMargin(top: House.Spacing.xs, bottom: House.Spacing.sm)
            }
        if findMarks {
            // Find in Chat: `~~hit~~` is a hit (hover fill, no strike line),
            // `[hit](rti-find:current)` the current one (selection fill, in
            // the prose's own ink). Real links and strikes are stripped from
            // the marked text first, so nothing else draws these fills.
            theme = theme
                .strikethrough { BackgroundColor(House.ColorToken.hoverFill) }
                .link {
                    ForegroundColor(House.ColorToken.textPrimary)
                    BackgroundColor(House.ColorToken.selectionFill)
                }
        }
        return theme
    }
}

/// A code block in an answer: a header strip on `well` with the language,
/// Wrap, and Copy, a hairline under it, then the code on `surfaceTint`.
/// Wrap starts off; the code then scrolls sideways.
private struct OverlayCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @State private var wraps = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HouseDivider()
            if wraps {
                code.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { code }
            }
        }
        .background(House.ColorToken.surfaceTint)
        .clipShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private var code: some View {
        configuration.label
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(.em(House.TypeToken.Size.code / House.TypeToken.Size.body))
                ForegroundColor(House.ColorToken.textPrimary)
            }
            .padding(House.Spacing.sm)
    }

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            Text(configuration.language?.isEmpty == false ? configuration.language ?? "" : "code")
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
            Spacer(minLength: House.Spacing.xs)
            stripButton(wraps ? "Unwrap" : "Wrap", symbol: "arrow.left.and.right", help: wraps ? "Scroll long lines" : "Wrap long lines") {
                wraps.toggle()
            }
            stripButton(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy the code") {
                NSPasteboard.copyString(configuration.content)
                copied = true
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.compact + House.Spacing.xxs)
        .background(House.ColorToken.well)
    }

    private func stripButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: House.Spacing.xxs) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
