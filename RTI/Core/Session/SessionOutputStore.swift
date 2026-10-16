import Foundation

/// Owns the one write that a saved-meeting output makes: a unique, owner-only
/// file under `<session>/outputs/`. An actor so every write is serialized and
/// the archive is never touched concurrently.
///
/// The store never overwrites: the destination is computed from the recipe id
/// and a timestamp, the write lands in a hidden temp file, and the final step
/// is a hard link that fails if the destination already exists. A failure
/// leaves no partial artifact behind. Every destination is checked for
/// containment inside the session's `outputs/` folder first.
public actor SessionOutputStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Generated outputs for one session, newest first. Read-only; never
    /// touches `transcript.md`, `summary.md`, or any other archive file.
    public func list(in sessionDirectory: URL) -> [SessionOutputArtifact] {
        Self.list(in: sessionDirectory, fileManager: fileManager)
    }

    /// Pure listing, so the Sessions reader can build its file chips
    /// synchronously without hopping onto the actor. Every candidate is
    /// re-checked for containment before its bytes are read, and the
    /// `outputs/` folder must be a real directory inside the session, so a
    /// symlinked folder or file can never pull in an outside document.
    public static func list(
        in sessionDirectory: URL,
        fileManager: FileManager = .default
    ) -> [SessionOutputArtifact] {
        guard let outputs = SessionOutputPaths.safeDirectory(in: sessionDirectory, fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: outputs.path)
        else { return [] }
        let artifacts: [SessionOutputArtifact] = names.compactMap { name in
            guard name.hasSuffix(".md"), !name.hasPrefix(".") else { return nil }
            let url = outputs.appendingPathComponent(name, isDirectory: false)
            guard SessionOutputPaths.isContained(url, in: sessionDirectory, fileManager: fileManager) else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            // Listing needs only a small provenance header, never every output's
            // full body on the UI thread. Missing/oversized headers use the filename.
            let bytes = (try? handle.read(upToCount: 16_384)) ?? Data()
            let text = String(decoding: bytes, as: UTF8.self)
            let provenance = SessionOutputMarkdown.parseProvenance(text)
            return SessionOutputArtifact(
                url: url,
                templateID: provenance?.templateID ?? url.deletingPathExtension().lastPathComponent,
                templateName: provenance?.templateName ?? "",
                generatedAt: provenance.map { SessionOutputMarkdown.parseGeneratedDate($0.generatedAt) } ?? nil
            )
        }
        return artifacts.sorted {
            let left = $0.generatedAt ?? .distantPast
            let right = $1.generatedAt ?? .distantPast
            if left == right { return $0.url.lastPathComponent > $1.url.lastPathComponent }
            return left > right
        }
    }

    /// Save one generated output. `now` names the file and is supplied by the
    /// caller so the writer is deterministic in tests.
    @discardableResult
    public func write(
        recipe: SessionOutputRecipe,
        provenance: SessionOutputProvenance,
        body: String,
        into sessionDirectory: URL,
        now: Date
    ) throws -> SessionOutputArtifact {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionOutputError.emptyOutput }
        guard SessionOutputID.isValid(recipe.id) else {
            throw SessionOutputError.writeFailed("unsafe recipe id \"\(recipe.id)\"")
        }
        // A cancelled job must never leave a partial artifact behind. Check
        // before the temp write and again before the atomic commit below.
        try Task.checkCancellation()

        let outputs = SessionOutputPaths.directory(in: sessionDirectory)
        // A symlinked `outputs/` is refused before anything is created or
        // written, even if it points back inside the session.
        if let values = try? outputs.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw SessionOutputError.uncontainedDestination
        }
        // An existing non-directory at the outputs path is a write error, not
        // a path to scribble through.
        var outputsIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputs.path, isDirectory: &outputsIsDirectory), !outputsIsDirectory.boolValue {
            throw SessionOutputError.writeFailed("the outputs path exists and is not a folder")
        }
        do {
            try fileManager.createDirectory(
                at: outputs,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SessionOutputError.writeFailed(error.localizedDescription)
        }
        // The folder must now be a real directory inside the session; a
        // symlinked `outputs/` is refused before any byte is written.
        guard let safeOutputs = SessionOutputPaths.safeDirectory(in: sessionDirectory, fileManager: fileManager) else {
            throw SessionOutputError.uncontainedDestination
        }

        let existing = Set((try? fileManager.contentsOfDirectory(atPath: safeOutputs.path)) ?? [])
        let name = SessionOutputMarkdown.fileName(
            recipeID: recipe.id,
            stamp: SessionOutputMarkdown.filenameStamp(now),
            existing: existing
        )
        let url = safeOutputs.appendingPathComponent(name, isDirectory: false)
        guard SessionOutputPaths.isContained(url, in: sessionDirectory, fileManager: fileManager) else {
            throw SessionOutputError.uncontainedDestination
        }

        let markdown = SessionOutputMarkdown.render(recipe: recipe, provenance: provenance, body: trimmed)
        let temp = safeOutputs.appendingPathComponent(".\(name).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try Data(markdown.utf8).write(to: temp, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            // The atomic commit. A cancel arriving before this point leaves
            // only the temp file, which is removed in the outer catch.
            try Task.checkCancellation()
            do {
                // Hard link: atomic, and it refuses an existing destination.
                try fileManager.linkItem(at: temp, to: url)
            } catch {
                let reason = error.localizedDescription
                try? fileManager.removeItem(at: temp)
                throw fileManager.fileExists(atPath: url.path)
                    ? SessionOutputError.destinationExists
                    : SessionOutputError.writeFailed(reason)
            }
            try? fileManager.removeItem(at: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }

        return SessionOutputArtifact(
            url: url,
            templateID: recipe.id,
            templateName: recipe.name,
            generatedAt: SessionOutputMarkdown.parseGeneratedDate(provenance.generatedAt)
        )
    }
}
