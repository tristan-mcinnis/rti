import AppKit
import Foundation
import PDFKit

/// Extracts plain text from a discussion-guide file in whatever container the
/// author exported it as. Markdown/text is read directly; Word (.docx/.doc),
/// RTF, and HTML go through `NSAttributedString`'s document importers; PDF goes
/// through PDFKit. The downstream parser only ever sees plain text, so this is
/// the single place format coverage grows — add a case here, not in the parser.
///
/// IMPORTANT: the HTML importer is WebKit-backed and must run on the main
/// thread. Every caller is `@MainActor` (DiscussionGuideController), so as long
/// as extraction is invoked synchronously from that context it stays on main.
enum GuideTextExtractor {

    enum ExtractError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return detail
            }
        }
    }

    /// Plain-text contents of `url`, dispatched on file extension. Throws with a
    /// human-readable message the UI can surface on the guide panel.
    static func text(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "text", "":
            return try readPlain(url)
        case "rtf", "rtfd", "doc", "docx", "html", "htm", "webarchive":
            return try readAttributed(url)
        case "pdf":
            return try readPDF(url)
        default:
            // Unknown extension — try plain text, then the rich importer, before
            // giving up, so an oddball export still has a chance.
            if let plain = try? readPlain(url) { return plain }
            if let rich = try? readAttributed(url) { return rich }
            throw ExtractError.unreadable(
                "Unsupported guide format “.\(url.pathExtension)”. Export as .md, .docx, .pdf, .rtf, or .txt."
            )
        }
    }

    private static func readPlain(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        var used: String.Encoding = .utf8
        return try String(contentsOf: url, usedEncoding: &used)
    }

    /// One path for RTF / Word / HTML — `NSAttributedString(url:)` sniffs the
    /// document type from the data, so we don't have to map extension → type.
    private static func readAttributed(_ url: URL) throws -> String {
        guard let attr = try? NSAttributedString(
            url: url, options: [:], documentAttributes: nil
        ) else {
            throw ExtractError.unreadable("Couldn't read \(url.lastPathComponent) — it may be password-protected or corrupt.")
        }
        return attr.string
    }

    private static func readPDF(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw ExtractError.unreadable("Couldn't open PDF \(url.lastPathComponent).")
        }
        let text = doc.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractError.unreadable("\(url.lastPathComponent) is an image-only PDF (no extractable text).")
        }
        return text
    }
}
