import AppKit
import SwiftUI
import HouseDesign

private extension String {
    func mdStripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

// MARK: - Rich-text pasteboard

extension NSPasteboard {
    /// Place both an RTF rendering AND the raw markdown string on the
    /// general pasteboard, so pasting into Word / Outlook / Apple Mail
    /// preserves formatting (headings, bold/italic, bullets) while
    /// pasting into plain-text editors still works.
    static func copyMarkdownRich(_ markdown: String) {
        let attr = MarkdownRTF.attributedString(from: markdown)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.rtf, .string], owner: nil)
        if let rtf = try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(markdown, forType: .string)
    }
}

/// Converts a markdown string into an `NSAttributedString` with paragraph
/// styling for headings and bullet hanging indents — suitable for RTF
/// export to Word / Outlook.
enum MarkdownRTF {
    static func attributedString(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        for (idx, raw) in lines.enumerated() {
            let isLast = idx == lines.count - 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                out.append(NSAttributedString(string: isLast ? "" : "\n"))
                continue
            }

            let (text, style) = classify(line: raw)
            let inlineAttr = renderInline(text, baseFont: style.font, baseColor: House.NSColorToken.textPrimary)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = style.spacingBefore
            para.paragraphSpacing = style.spacingAfter
            if style.isBullet {
                para.headIndent = 16
                para.firstLineHeadIndent = 0
            }
            inlineAttr.addAttribute(.paragraphStyle, value: para,
                                    range: NSRange(location: 0, length: inlineAttr.length))
            out.append(inlineAttr)
            if !isLast {
                out.append(NSAttributedString(string: "\n"))
            }
        }
        return out
    }

    private struct LineStyle {
        var font: NSFont
        var spacingBefore: CGFloat = 0
        var spacingAfter: CGFloat = 2
        var isBullet: Bool = false
    }

    private static func classify(line raw: String) -> (text: String, style: LineStyle) {
        if let s = raw.mdStripPrefix("### ") {
            return (s, LineStyle(font: NSFont.boldSystemFont(ofSize: 13), spacingBefore: 6, spacingAfter: 3))
        }
        if let s = raw.mdStripPrefix("## ") {
            return (s, LineStyle(font: NSFont.boldSystemFont(ofSize: 15), spacingBefore: 8, spacingAfter: 4))
        }
        if let s = raw.mdStripPrefix("# ") {
            return (s, LineStyle(font: NSFont.boldSystemFont(ofSize: 17), spacingBefore: 10, spacingAfter: 4))
        }
        if let s = raw.mdStripPrefix("- [x] ") ?? raw.mdStripPrefix("* [x] ")
            ?? raw.mdStripPrefix("- [X] ") ?? raw.mdStripPrefix("* [X] ") {
            return ("☑︎ \(s)", LineStyle(font: NSFont.systemFont(ofSize: 12), isBullet: true))
        }
        if let s = raw.mdStripPrefix("- [ ] ") ?? raw.mdStripPrefix("* [ ] ") {
            return ("☐ \(s)", LineStyle(font: NSFont.systemFont(ofSize: 12), isBullet: true))
        }
        if let s = raw.mdStripPrefix("- ") ?? raw.mdStripPrefix("* ") {
            return ("•  \(s)", LineStyle(font: NSFont.systemFont(ofSize: 12), isBullet: true))
        }
        return (raw, LineStyle(font: NSFont.systemFont(ofSize: 12)))
    }

    /// Inline emphasis via Apple's markdown parser, then mapped to NSFont
    /// traits so the RTF round-trip keeps bold/italic.
    private static func renderInline(_ text: String, baseFont: NSFont, baseColor: NSColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: baseColor])
        // Best-effort inline markdown via AttributedString → NSAttributedString.
        if let attr = try? AttributedString(markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let ns = NSMutableAttributedString(attr)
            // Apply baseFont where no explicit font from markdown parsing.
            let full = NSRange(location: 0, length: ns.length)
            ns.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                let font: NSFont = {
                    guard let existing = value as? NSFont else { return baseFont }
                    let traits = existing.fontDescriptor.symbolicTraits
                    var descriptor = baseFont.fontDescriptor
                    if traits.contains(.bold) || traits.contains(.italic) {
                        descriptor = descriptor.withSymbolicTraits(traits)
                    }
                    return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
                }()
                ns.addAttribute(.font, value: font, range: range)
                ns.addAttribute(.foregroundColor, value: baseColor, range: range)
            }
            return ns
        }
        return result
    }
}
