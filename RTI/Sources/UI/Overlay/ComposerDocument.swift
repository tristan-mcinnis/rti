import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

// MARK: - Documents in the strip

/// One document chosen for the next question: reading, read, or failed.
struct ComposerDocument: Identifiable, Equatable {
    enum Phase: Equatable {
        case reading
        case ready(ExternalDocumentAttachment)
        case failed(String)
    }

    let id: UUID
    let name: String
    let sourceURL: URL?
    var phase: Phase

    init(id: UUID = UUID(), name: String, phase: Phase, sourceURL: URL? = nil) {
        self.id = id
        self.name = name
        self.phase = phase
        self.sourceURL = sourceURL?.standardizedFileURL
    }

    var attachment: ExternalDocumentAttachment? {
        if case .ready(let attachment) = phase { return attachment }
        return nil
    }

    var isReading: Bool { phase == .reading }

    func isSameSource(as url: URL) -> Bool {
        sourceURL == url.standardizedFileURL
    }

    var chip: AttachmentChipModel {
        switch phase {
        case .ready(let attachment):
            return AttachmentChipModel(ref: attachment.ref, id: id.uuidString)
        case .reading:
            return AttachmentChipModel(id: id.uuidString, kind: Self.chipKind(forName: name), name: name, phase: .reading)
        case .failed(let reason):
            return AttachmentChipModel(id: id.uuidString, kind: Self.chipKind(forName: name), name: name, phase: .failed(reason))
        }
    }

    /// A reading or failed chip still names the right kind: an image file is
    /// not a text file, even before its bytes are read.
    private static func chipKind(forName name: String) -> ChatAttachmentRef.Kind {
        let lower = name.lowercased()
        if lower.hasSuffix(".pdf") { return .pdf }
        if [".png", ".jpg", ".jpeg", ".heic", ".gif", ".tiff", ".webp"].contains(where: { lower.hasSuffix($0) }) {
            return .image
        }
        return .text
    }
}

/// Render-proof seam: a composer state set up front, so a proof can draw a
/// state the live controllers cannot be put in (a stream, an open layer).
/// Nil in the app.
struct ComposerRenderSeed {
    enum Layer {
        case none, addContext, searchScope, palette
    }

    var draft = ""
    /// Overrides `LLMController.streaming`.
    var isStreaming: Bool?
    var isQueued = false
    var layer: Layer = .none
    /// Stands in for the vault's mention search.
    var mentionCandidates: [String]?
    /// The rows the `@` chooser draws, when a proof needs RTI's project,
    /// meeting and file rows without a vault read.
    var mentionRows: [AddContextRow]?
    /// Stands in for `LLMController.pendingScreenImage`, so a proof can draw
    /// the image route.
    var pendingImage: Bool?
    /// Stands in for the store's own answer: false is "no vault configured".
    var savesToVault: Bool?
    /// Stands in for `LLMController.broaderSearchEnabled`.
    var isBroaderSearch: Bool?
    /// Stands in for `LLMController.retainedSourceNotice`, so a proof can draw
    /// the state without a vault write.
    var retainedNotice: String?
    /// Stands in for `LLMController.retrievalDiagnostic`.
    var retrievalNotice: String?
    /// Stands in for `LLMController.vaultWithheldNotice`: a chat whose attached
    /// sources keep the vault tools withheld, so a proof can draw the exact
    /// line without a vault or a provider.
    var vaultWithheldNotice: String?
    /// Stands in for the resolved route, so a proof does not depend on the
    /// machine's credential store.
    var route: ComposerRoutePreview?
    /// Stands in for `LLMController.pendingDatedSourceName`: a dated log handed
    /// over from the Chats library, which grounds the next turn.
    var pendingDatedSourceName: String?
    var mentionPaths: [String] = []
    var documents: [ComposerDocument] = []
    var isDropTargeted = false
    var focusedChipID: String?
    var chooserIndex = 0
}
