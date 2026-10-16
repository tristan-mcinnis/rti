import Foundation
import RTICore

/// Archived transcript and session details in; one separate output out.
/// No audio, retranscription, live-session globals or automatic sending.
@MainActor
enum SessionOutputGenerator {
    typealias Collect = @Sendable ([LLMMessage], ChatRouteConfiguration) async throws -> LLMClient.CollectedResponse

    static let store = SessionOutputStore()
    private static let reader = SessionOutputSourceReader()
    static let timeout: Double = 300

    @discardableResult
    static func generate(
        recipe: SessionOutputRecipe,
        sessionDirectory: URL,
        folderName: String,
        route: ChatRouteConfiguration,
        now: Date = Date(),
        collect: Collect? = nil
    ) async throws -> SessionOutputArtifact {
        let source = try await reader.read(sessionDirectory: sessionDirectory, folderName: folderName)
        let snapshot = source.snapshot
        let transcript = SessionOutputPrompt.applyingSpeakerNames(
            to: SessionOutputPrompt.stripFrontmatter(source.transcript), names: snapshot.speakerNames
        )
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionOutputError.missingTranscript
        }
        let prompt = SessionOutputPrompt.text(
            instruction: recipe.instruction, context: snapshot.promptContext, transcript: transcript
        )
        let messages = [LLMMessage(role: "user", content: prompt)]
        let response: LLMClient.CollectedResponse
        do {
            if let collect {
                response = try await collect(messages, route)
            } else {
                response = try await LLMRequest(priority: .background).collectDetailedThrowingAsync(
                    messages: messages, smart: false, route: route, timeoutOverride: timeout
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            throw SessionOutputError.requestFailed(error.userMessage)
        } catch let error as LLMRequestSchedulingError {
            throw SessionOutputError.requestFailed(error.localizedDescription)
        } catch {
            throw SessionOutputError.requestFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        if response.finishReason == "length" { throw SessionOutputError.truncatedOutput }
        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SessionOutputError.emptyOutput }
        let provider = route.provider
        let provenance = SessionOutputProvenance(
            templateID: recipe.id,
            templateName: recipe.name,
            templateHash: recipe.templateHash,
            sourceFile: "transcript.md",
            sourceHash: PromptDefaults.fnv1a(source.transcript),
            sourceBytes: source.sourceBytes,
            sessionFolder: snapshot.sessionFolder,
            sessionID: snapshot.sessionID,
            mode: snapshot.mode,
            providerID: provider.id,
            providerName: provider.displayName,
            model: provider.model,
            endpoint: SessionOutputMarkdown.sanitizedEndpoint(provider.baseURL),
            generatedAt: isoFormatter.string(from: now)
        )
        return try await store.write(
            recipe: recipe, provenance: provenance, body: body, into: sessionDirectory, now: now
        )
    }

    static func outputs(in sessionDirectory: URL) async -> [SessionOutputArtifact] {
        await store.list(in: sessionDirectory)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
