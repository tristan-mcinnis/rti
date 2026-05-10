import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import Hub
import HuggingFace
import Tokenizers

import MLX
import MLXLMCommon
import MLXVLM

// MARK: - Hub Downloader Bridge

/// Adapts a `HuggingFace.HubClient` into an `MLXLMCommon.Downloader`,
/// matching what the `#hubDownloader` macro produces.
private struct HubDownloader: Downloader {
    let client: HubClient

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw VLMError.invalidRepoID(id)
        }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

// MARK: - Tokenizer Bridge

/// Adapts a `Tokenizers.Tokenizer` into an `MLXLMCommon.Tokenizer`,
/// matching what the `#adaptHuggingFaceTokenizer` macro produces.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads a `Tokenizers.Tokenizer` from a local directory via `AutoTokenizer`,
/// matching what the `#huggingFaceTokenizerLoader` macro produces.
private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

// MARK: - Errors

private enum VLMError: LocalizedError {
    case invalidRepoID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            return "Invalid HuggingFace repository ID: \(id)"
        }
    }
}

// MARK: - VLM Manager

@MainActor
final class VLMManager {
    static let shared = VLMManager()

    /// The model loaded in-memory. Nil until `load()` completes.
    private var modelContainer: ModelContainer?

    /// True while the model is downloading / loading.
    private(set) var isLoading = false

    /// True once the model is ready for inference.
    private(set) var isLoaded = false

    /// Most recent error, for UI diagnostics.
    private(set) var lastError: String?

    // MARK: Model configuration

    /// Qwen3-VL-2B-Instruct 4-bit quantised. Same model the voice-agent uses.
    /// Auto-downloaded from HuggingFace on first call if not already cached.
    private static let modelID = "mlx-community/Qwen3-VL-2B-Instruct-4bit"

    static let defaultPrompt =
        "Describe what you see in this screenshot in 1–2 concise sentences. Include any visible text."

    private init() {}

    // MARK: - Public API

    /// Load the VLM into memory. Subsequent calls are no-ops.
    /// First load may download ~2 GB from HuggingFace.
    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            let downloader = HubDownloader(client: HubClient())
            let tokenizerLoader = TransformersTokenizerLoader()
            let config = ModelConfiguration(
                id: Self.modelID,
                defaultPrompt: Self.defaultPrompt
            )

            let container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: config
            ) { [weak self] progress in
                Task { @MainActor in
                    let pct = Int(progress.fractionCompleted * 100)
                    NSLog("[RTI] VLMManager: download progress \(pct)%")
                }
            }
            self.modelContainer = container
            isLoaded = true
            lastError = nil
            NSLog("[RTI] VLMManager: model loaded — \(Self.modelID)")
        } catch {
            lastError = error.localizedDescription
            NSLog("[RTI] VLMManager: load failed — \(error)")
        }
    }

    /// Run the VLM on a screenshot and return a text description.
    /// Triggers load if the model hasn't been loaded yet.
    ///
    /// - Parameter cgImage: The screenshot captured by ScreenshotManager.
    /// - Returns: A 1–2 sentence text description, or nil on failure.
    func describe(cgImage: CGImage) async -> String? {
        // Ensure model is loaded.
        if !isLoaded {
            await load()
            guard isLoaded else { return nil }
        }
        guard let container = modelContainer else { return nil }

        // Write the CGImage to a temporary JPEG so the VLM can read it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard writeJPEG(cgImage, to: tempURL) else {
            NSLog("[RTI] VLMManager: failed to write temp JPEG")
            return nil
        }

        do {
            let prompt = Self.defaultPrompt

            var fullResponse = ""

            let stream = try await container.perform { context in
                let userInput = UserInput(
                    chat: [
                        Chat.Message.user(
                            prompt,
                            images: [.url(tempURL)]
                        )
                    ],
                    processing: .init(resize: .init(width: 1024, height: 1024))
                )
                let lmInput = try await context.processor.prepare(input: userInput)
                let parameters = GenerateParameters(maxTokens: 150, temperature: 0.0)
                return try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context
                )
            }

            for await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    fullResponse += chunk
                case .info:
                    break
                case .toolCall:
                    break
                }
            }

            let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                NSLog("[RTI] VLMManager: described image — \(trimmed.count) chars")
                return trimmed
            }
            return nil
        } catch {
            NSLog("[RTI] VLMManager: generation failed — \(error)")
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    private func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, kUTTypeJPEG, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
