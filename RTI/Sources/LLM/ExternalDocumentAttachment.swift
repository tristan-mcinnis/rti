import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A document selected for one Assist turn. Its extracted text lives only in
/// memory and is discarded after the request; RTI never copies the source file
/// into the vault or session archive.
struct ExternalDocumentAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
}

enum ExternalDocumentLoader {
    private static let maxBytes = 512 * 1024
    private static let maxCharacters = 24_000

    enum LoadError: LocalizedError {
        case unsupported(String)
        case tooLarge
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case let .unsupported(name): "\(name) isn't a supported attachment. Attach a PDF, Markdown, or plain-text file."
            case .tooLarge: "That file is too large to attach. Choose a file under 512 KB."
            case .unreadable: "RTI couldn't read that file."
            case .noText: "No readable text was found in that file."
            }
        }
    }

    static func load(url: URL) throws -> ExternalDocumentAttachment {
        guard url.isFileURL else { throw LoadError.unreadable }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maxBytes else { throw LoadError.tooLarge }

        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let text: String
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw LoadError.unreadable }
            text = document.string ?? ""
        } else if type.conforms(to: .text) || ["md", "markdown", "csv", "json", "yaml", "yml"].contains(url.pathExtension.lowercased()) {
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? ""
        } else {
            throw LoadError.unsupported(url.lastPathComponent)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoadError.noText }
        return ExternalDocumentAttachment(name: url.lastPathComponent, text: String(trimmed.prefix(maxCharacters)))
    }
}
