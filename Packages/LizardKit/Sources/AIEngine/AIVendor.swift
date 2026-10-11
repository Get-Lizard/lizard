import Foundation

/// The AI company an extension asked for (Raycast's `AI.Model`, e.g. `"Anthropic_Claude_Sonnet"`,
/// `"openai-gpt-4o"`). Lizard has no models of its own to sell: a request is answered by the
/// person's own matching account when they have one (and allow cloud AI), else by whatever
/// they set up, on-device first.
public enum AIVendor: String, Sendable, CaseIterable {
    case anthropic, openAI, google

    public init?(modelName: String?) {
        guard let name = modelName?.lowercased(), !name.isEmpty else { return nil }
        if name.contains("anthropic") || name.contains("claude") {
            self = .anthropic
        } else if name.contains("openai") || name.contains("gpt") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            self = .openAI
        } else if name.contains("google") || name.contains("gemini") {
            self = .google
        } else {
            return nil
        }
    }

    /// Whether `provider` already talks to this vendor directly (an API key for it, or OpenRouter
    /// set to one of its models).
    public func serves(_ provider: any AIProvider) -> Bool {
        let id = provider.id.lowercased()
        switch self {
        case .anthropic: return id.hasPrefix("anthropic:") || (id.contains("openrouter") && id.contains("anthropic/"))
        case .openAI: return id.hasPrefix("openai:") || (id.contains("openrouter") && id.contains("openai/"))
        case .google: return id.contains("openrouter") && id.contains("google/")
        }
    }

    /// A good default on OpenRouter when the person has OpenRouter but not this vendor's key.
    public var openRouterModel: String {
        switch self {
        case .anthropic: "anthropic/claude-sonnet-5.5"
        case .openAI: "openai/gpt-5"
        case .google: "google/gemini-2.5-pro"
        }
    }

    /// Providers in the order to try for this vendor: its own accounts first, then the rest.
    /// `openRouter` builds an OpenRouter provider for a model (nil when not signed in).
    public static func order(
        _ providers: [any AIProvider], for modelName: String?, cloudAllowed: Bool,
        openRouter: (String) -> (any AIProvider)?
    ) -> [any AIProvider] {
        guard cloudAllowed, let vendor = AIVendor(modelName: modelName) else { return providers }
        let direct = providers.filter { vendor.serves($0) }
        let rest = providers.filter { !vendor.serves($0) }
        if !direct.isEmpty { return direct + rest }
        if let routed = openRouter(vendor.openRouterModel) { return [routed] + providers }
        return providers
    }
}
