import Foundation

/// How much thinking one turn is allowed to do. `fast` explicitly disables a
/// provider's reasoning extension; `thinking` asks for it where the provider
/// supports it.
public enum ChatReasoningMode: String, Codable, Sendable, CaseIterable {
    case fast
    case thinking

    public var label: String {
        switch self {
        case .fast: "Fast"
        case .thinking: "Thinking"
        }
    }

    public var symbolName: String {
        switch self {
        case .fast: "bolt"
        case .thinking: "brain"
        }
    }
}

/// Where a turn's images go. Recorded on every turn so the destination is a
/// fact in the log, not a claim in the UI.
public enum ChatImageRoute: String, Codable, Sendable, CaseIterable {
    /// The turn carries no images.
    case none
    /// Images are sent to the provider as inline `data:` content.
    case cloudInline
    /// Images stayed on this Mac; only OCR text reached the model.
    case textOnly

    public var isCloud: Bool { self == .cloudInline }
}

/// What the user picked for one chat. Provider and model are per chat; the
/// app default only supplies the initial value.
public struct ChatModelSelection: Sendable, Equatable {
    public var providerId: String
    /// Nil means "the provider's own configured model".
    public var model: String?
    public var reasoning: ChatReasoningMode

    public init(
        providerId: String,
        model: String? = nil,
        reasoning: ChatReasoningMode = .fast
    ) {
        self.providerId = providerId
        self.model = model
        self.reasoning = reasoning
    }
}

/// Provider facts a route needs that `LLMProviderConfig` does not carry:
/// which of its models take image input, and the one visibly-labelled
/// fallback the user has accepted for a text-only model.
///
/// RTI's providers ship a single model each, so `visionModelIds` is usually
/// empty and `LLMProviderConfig.supportsVision` answers for the model. A
/// provider that gains a second model fills this in; the resolver already
/// honours it.
public struct ChatRouteOptions: Sendable, Equatable {
    /// Model ids that accept image content. Empty means "the provider's own
    /// model, judged by `LLMProviderConfig.supportsVision`".
    public var visionModelIds: [String]
    /// A model the user accepted as a visibly-labelled fallback when the
    /// selected model cannot take images. Nil means an image turn degrades
    /// to text-only (or blocks, when the caller requires cloud inference)
    /// rather than switching model behind the user's back.
    public var visionFallbackModelId: String?

    public init(visionModelIds: [String] = [], visionFallbackModelId: String? = nil) {
        self.visionModelIds = visionModelIds
        self.visionFallbackModelId = visionFallbackModelId
    }

    /// Does this provider accept images for `model`?
    public func acceptsImages(forModel model: String, provider: LLMProviderConfig) -> Bool {
        visionModelIds.isEmpty ? provider.supportsVision : visionModelIds.contains(model)
    }
}

/// Why a turn could not run. A blocked route never silently switches
/// provider, model, or credential store; it names the fix.
public enum ChatRouteBlocker: Error, Sendable, Equatable {
    case missingCredential(providerName: String)
    case imagesUnsupported(providerName: String, model: String)

    public var message: String {
        switch self {
        case let .missingCredential(providerName):
            "\(providerName) has no API key. Add one in Settings → Keys to send this."
        case let .imagesUnsupported(providerName, model):
            "\(providerName) · \(model) cannot read images. Remove the image or pick a vision model."
        }
    }
}

/// One turn's frozen route: the provider snapshot, the model, the reasoning
/// mode, and where images go. Built once at send time and passed down through
/// `LLMRequest`, `ToolLoop`, and `LLMClient`, so a Settings change or a
/// provider switch mid-turn cannot alter the turn that is already running.
///
/// The durable form of this is a `HouseChatCore.RequestReceipt`, built by
/// `ChatTurnReceipt` in the app target. This type stays free of the package so
/// the package's schema can keep changing without touching the freeze.
public struct ChatRouteConfiguration: Sendable {
    /// The provider snapshot. Its `model` is already the effective model and
    /// its `apiKey` closure returns the key captured when the route froze.
    public let provider: LLMProviderConfig
    public let reasoning: ChatReasoningMode
    public let imageRoute: ChatImageRoute
    public let imageCount: Int
    /// What the user had chosen, before the freeze applied a thinking override
    /// or a vision fallback.
    public let selection: ChatModelSelection

    public init(
        provider: LLMProviderConfig,
        reasoning: ChatReasoningMode,
        imageRoute: ChatImageRoute,
        imageCount: Int,
        selection: ChatModelSelection
    ) {
        self.provider = provider
        self.reasoning = reasoning
        self.imageRoute = imageRoute
        self.imageCount = imageCount
        self.selection = selection
    }

    /// The value the client's `smart:` parameter used to carry.
    public var smart: Bool { thinkingSent }

    /// True when the provider actually received a thinking directive. False
    /// when the user asked for thinking on a provider that does not support
    /// it, so the record never claims reasoning that did not happen.
    public var thinkingSent: Bool { reasoning == .thinking && provider.supportsThinking }

    public var model: String { provider.model }

    public var allowsImages: Bool { imageRoute == .cloudInline }

    /// True when the turn ran on a labelled vision fallback instead of the
    /// model the user picked.
    public var isVisionFallback: Bool {
        provider.model != (selection.model ?? provider.model)
    }

    /// The destination label the composer shows before Send.
    public var imageRouteLabel: String {
        switch imageRoute {
        case .none:
            ""
        case .cloudInline:
            "Images go to \(provider.displayName) (cloud)"
        case .textOnly:
            "Images stay on this Mac; text only"
        }
    }

    /// The one line a thread draws under an answer: who ran it, how, and
    /// where images went.
    public var routeLabel: String {
        var parts = [provider.displayName, provider.model, reasoning.label]
        if imageCount > 0 {
            parts.append(imageRoute == .cloudInline ? "images → cloud" : "images → text only")
        }
        if isVisionFallback { parts.append("vision fallback") }
        return parts.joined(separator: " · ")
    }
}

/// Resolves the frozen route from the per-chat selection and the provider
/// registry entry. Pure: the app supplies the provider and its options, the
/// resolver decides the effective model, whether thinking goes on the wire,
/// and whether images may be sent — or blocks with a reason.
public enum ChatRouteResolver {
    public static func resolve(
        selection: ChatModelSelection,
        provider: LLMProviderConfig,
        options: ChatRouteOptions = ChatRouteOptions(),
        imageCount: Int = 0,
        requireCloudImages: Bool = false
    ) -> Result<ChatRouteConfiguration, ChatRouteBlocker> {
        let key = provider.apiKey()
        guard !key.isEmpty else {
            return .failure(.missingCredential(providerName: provider.displayName))
        }

        let requestedModel = selection.model ?? provider.model
        let hasImages = imageCount > 0

        var effectiveModel = requestedModel
        var imageRoute: ChatImageRoute = .none
        if hasImages {
            if options.acceptsImages(forModel: requestedModel, provider: provider) {
                imageRoute = .cloudInline
            } else if let fallback = options.visionFallbackModelId,
                      fallback != requestedModel,
                      options.acceptsImages(forModel: fallback, provider: provider)
            {
                // The one labelled exception: the user accepted this fallback.
                effectiveModel = fallback
                imageRoute = .cloudInline
            } else if requireCloudImages {
                // A caller that needs cloud inference gets a reason, never a
                // quiet switch to another provider or model.
                return .failure(.imagesUnsupported(
                    providerName: provider.displayName,
                    model: requestedModel
                ))
            } else {
                // Images stay on this Mac and only their text reaches the
                // model. Labelled, not silent.
                imageRoute = .textOnly
            }
        }

        let frozenProvider = LLMProviderConfig(
            id: provider.id,
            displayName: provider.displayName,
            baseURL: provider.baseURL,
            model: effectiveModel,
            supportsThinking: provider.supportsThinking,
            supportsVision: provider.supportsVision,
            apiKey: { key }
        )

        return .success(ChatRouteConfiguration(
            provider: frozenProvider,
            reasoning: selection.reasoning,
            imageRoute: imageRoute,
            imageCount: imageCount,
            selection: selection
        ))
    }
}
