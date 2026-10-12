import Foundation
import Security
import Synchronization

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, mlx, openAICompatible, anthropic, openAI, openRouter, openCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: "Apple Intelligence (on-device)"
        case .mlx: "On this Mac (MLX)"
        case .openAICompatible: "Ollama / LM Studio (local server)"
        case .anthropic: "Anthropic Claude"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter (Claude, GPT & more)"
        case .openCode: "OpenCode Zen"
        }
    }

    /// Short name for menus and badges.
    public var shortTitle: String {
        switch self {
        case .apple: "Apple"
        case .mlx: "On this Mac"
        case .openAICompatible: "Ollama"
        case .anthropic: "Claude"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode"
        }
    }

    public var isCloud: Bool { self == .anthropic || self == .openAI || self == .openRouter || self == .openCode }
}

/// Which AI answers in Lizard. Local-first: Apple's on-device model or an MLX model; clouds
/// are opt-in (`cloudEnabled`) to keep the "zero cloud" default. Secrets live in the Keychain.
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var main: ProviderKind = .mlx
    /// When the main AI fails (not downloaded, unavailable), try the other local one, then clouds if enabled.
    public var auto = true
    /// Off by default: nothing leaves the Mac unless the user turns this on.
    public var cloudEnabled = false
    public var mlxModelID = ModelCatalog.launcherDefault(budgetBytes: nil).id
    /// Ollama (or any OpenAI-compatible local server).
    public var openAIBaseURL = "http://localhost:11434/v1"
    public var openAIModel = "qwen3:8b"
    public var anthropicModel = AnthropicProvider.defaultModel
    public var anthropicEffort = "low"
    public var openAICloudModel = ""
    public var openRouterModel = OpenRouterFree.autoMixedID
    /// Empty: Zen's default coding model.
    public var openCodeModel = ""

    public static let defaultOpenRouterModel = "anthropic/claude-sonnet-5.5"

    public init() {}

    /// Tolerant decoding: missing keys keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProviderSettings()
        main = (try? c.decodeIfPresent(ProviderKind.self, forKey: .main)) ?? d.main
        auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? d.auto
        cloudEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .cloudEnabled)) ?? d.cloudEnabled
        mlxModelID = (try? c.decodeIfPresent(String.self, forKey: .mlxModelID)) ?? d.mlxModelID
        openAIBaseURL = (try? c.decodeIfPresent(String.self, forKey: .openAIBaseURL)) ?? d.openAIBaseURL
        openAIModel = (try? c.decodeIfPresent(String.self, forKey: .openAIModel)) ?? d.openAIModel
        anthropicModel = (try? c.decodeIfPresent(String.self, forKey: .anthropicModel)) ?? d.anthropicModel
        anthropicEffort = (try? c.decodeIfPresent(String.self, forKey: .anthropicEffort)) ?? d.anthropicEffort
        openAICloudModel = (try? c.decodeIfPresent(String.self, forKey: .openAICloudModel)) ?? d.openAICloudModel
        openRouterModel = (try? c.decodeIfPresent(String.self, forKey: .openRouterModel)) ?? d.openRouterModel
        openCodeModel = (try? c.decodeIfPresent(String.self, forKey: .openCodeModel)) ?? d.openCodeModel
    }

    private static let defaultsKey = "Lizard.ProviderSettings"

    public static func hasSaved(in defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: defaultsKey) != nil
    }

    public static func load(from defaults: UserDefaults = .standard) -> ProviderSettings {
        guard let data = defaults.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Main first; in Auto the other local engine next, then (only when allowed) every cloud.
    public var activeOrder: [ProviderKind] {
        var order = [main]
        guard auto else { return order.filter { cloudEnabled || !$0.isCloud } }
        for local in [ProviderKind.apple, .mlx] where !order.contains(local) { order.append(local) }
        if cloudEnabled {
            for cloud in [ProviderKind.openRouter, .openCode, .anthropic, .openAI] where !order.contains(cloud) { order.append(cloud) }
        }
        return order.filter { cloudEnabled || !$0.isCloud }
    }
}

/// API keys in the Keychain, stored together in ONE item, so macOS asks for access at most
/// once (each item has its own access prompt). Loaded once into memory; views read the cache.
public enum Keychain {
    private static let service = "io.lizard.app"
    private static let storeAccount = "api-keys"

    /// `nil` until loaded.
    private static let state = Mutex<[String: String]?>(nil)
    /// Serialises the (possibly prompting) first load so it happens once.
    private static let loading = Mutex(())

    public static func get(_ account: String) -> String? {
        load()[account]
    }

    /// The cached value without touching the Keychain: `nil` when keys aren't loaded yet.
    public static func cachedValue(_ account: String) -> String?? {
        state.withLock { stored in stored.map { $0[account] } }
    }

    /// Loads keys into memory. Call off the main thread at launch (a read can wait on an access prompt).
    public static func prefetch() {
        _ = load()
    }

    public static func set(_ value: String?, for account: String) {
        var keys = load()
        if let value, !value.isEmpty { keys[account] = value } else { keys[account] = nil }
        state.withLock { $0 = keys }
        write(keys)
    }

    public static var allAccounts: [String] { [anthropicAccount, openAIAccount, openAICloudAccount, openRouterAccount, openCodeAccount] }

    private static func load() -> [String: String] {
        if let keys = state.withLock({ $0 }) { return keys }
        return loading.withLock { _ in
            if let keys = state.withLock({ $0 }) { return keys }
            let keys: [String: String]
            switch readItem(storeAccount) {
            case .found(let data):
                keys = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            case .notFound:
                keys = migrateLegacyItems()
            case .unavailable:
                // Access denied/cancelled: work without keys this session, and never overwrite the store.
                keys = [:]
            }
            state.withLock { $0 = keys }
            return keys
        }
    }

    /// Older versions kept one item per key; fold them into the single store (one-time).
    private static func migrateLegacyItems() -> [String: String] {
        var keys: [String: String] = [:]
        var complete = true
        for account in allAccounts {
            switch readItem(account) {
            case .found(let data):
                let value = String(decoding: data, as: UTF8.self)
                if !value.isEmpty { keys[account] = value }
            case .notFound:
                break
            case .unavailable:
                complete = false
            }
        }
        write(keys)
        // Only remove the old items once they were all read successfully.
        if complete { for account in allAccounts { deleteItem(account) } }
        return keys
    }

    private static func write(_ keys: [String: String]) {
        deleteItem(storeAccount)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        var attributes = baseQuery(storeAccount)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Lizard API keys"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private enum ReadResult {
        case found(Data), notFound, unavailable
    }

    private static func readItem(_ account: String) -> ReadResult {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map(ReadResult.found) ?? .unavailable
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }

    private static func deleteItem(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static let anthropicAccount = "anthropic-api-key"
    public static let openAIAccount = "openai-compatible-api-key"
    public static let openAICloudAccount = "openai-api-key"
    public static let openRouterAccount = "openrouter-api-key"
    public static let openCodeAccount = "opencode-zen-api-key"
}

extension ProviderSettings {
    /// Builds the configured HTTP providers. MLX is built by the app (it links AIEngineMLX);
    /// pass it via `mlx`. Providers without credentials are skipped.
    /// - Parameter key: how to look up API keys (the app passes a cache-only lookup so it never
    ///   blocks the main thread on the Keychain).
    /// For chat: a connected cloud AI first (when cloud is allowed), then Apple Intelligence, then
    /// the local model. Clouds without a key are skipped, so with none it's Apple Intelligence.
    public var chatOrder: [ProviderKind] {
        let clouds: [ProviderKind] = cloudEnabled ? [main].filter(\.isCloud) + [.openRouter, .openCode, .anthropic, .openAI] : []
        var order: [ProviderKind] = []
        for kind in clouds + [.apple, .mlx] where !order.contains(kind) { order.append(kind) }
        return order
    }

    public func makeProviders(mlx: (any AIProvider)?, key: (String) -> String? = Keychain.get, order: [ProviderKind]? = nil) -> [any AIProvider] {
        (order ?? activeOrder).compactMap { kind -> (any AIProvider)? in
            switch kind {
            case .apple:
                return AppleIntelligence.isAvailable ? AppleFMProvider() : nil
            case .mlx:
                return mlx
            case .openAICompatible:
                guard let url = URL(string: openAIBaseURL) else { return nil }
                let label = openAIBaseURL.contains("11434") ? "Ollama" : "OpenAI-compatible"
                return OpenAICompatibleProvider(baseURL: url, model: openAIModel, apiKey: key(Keychain.openAIAccount), label: label)
            case .anthropic:
                let key = key(Keychain.anthropicAccount) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
                guard let key else { return nil }
                return AnthropicProvider(apiKey: key, model: anthropicModel, effort: anthropicEffort)
            case .openAI:
                let key = key(Keychain.openAICloudAccount) ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
                guard let key else { return nil }
                // Responses API: required for reasoning models with tools.
                return OpenAIResponsesProvider(apiKey: key, model: openAICloudModel.isEmpty ? "gpt-5" : openAICloudModel)
            case .openCode:
                guard let key = key(Keychain.openCodeAccount) ?? OpenCodeZen.keyFromCLI()
                    ?? ProcessInfo.processInfo.environment["OPENCODE_API_KEY"] else { return nil }
                return OpenCodeZen.provider(apiKey: key, model: openCodeModel)
            case .openRouter:
                guard let key = key(Keychain.openRouterAccount) else { return nil }
                if let route = OpenRouterFree.routing(for: openRouterModel) {
                    return OpenAICompatibleProvider(
                        baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: route.model, apiKey: key, label: "OpenRouter",
                        fallbackModels: route.fallbacks)
                }
                return OpenAICompatibleProvider(
                    baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: openRouterModel, apiKey: key, label: "OpenRouter")
            }
        }
    }
}
