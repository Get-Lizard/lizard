import Foundation

/// Lists the models a provider account can use, and picks a sensible default.
public enum ModelDirectory {
    public struct RemoteModel: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let created: Date?
        /// Costs nothing to use (OpenRouter's free models).
        public var isFree = false
        /// US dollars per million tokens (input, output), when the service publishes prices.
        public var inputPrice: Double?
        public var outputPrice: Double?
        /// How much text it can read at once (tokens).
        public var contextLength: Int?

        public init(id: String, name: String, created: Date?, isFree: Bool = false, inputPrice: Double? = nil, outputPrice: Double? = nil, contextLength: Int? = nil) {
            self.id = id
            self.name = name
            self.created = created
            self.isFree = isFree
            self.inputPrice = inputPrice
            self.outputPrice = outputPrice
            self.contextLength = contextLength
        }
    }

    public enum DirectoryError: Error, LocalizedError {
        case http(Int, String)
        case unreachable(String)

        public var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _): "The API key was rejected. Check that it's correct and active."
            case .http(let status, let body): "The service answered \(status): \(body.prefix(200))"
            case .unreachable(let detail): "Couldn't reach the service: \(detail)"
            }
        }
    }

    // MARK: Anthropic

    public static func anthropicModels(apiKey: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let json = try await fetch(request)
        let data = (json["data"] as? [[String: Any]]) ?? []
        let formatter = ISO8601DateFormatter()
        return data.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return RemoteModel(id: id, name: entry["display_name"] as? String ?? id, created: (entry["created_at"] as? String).flatMap(formatter.date))
        }
    }

    /// Opus 5.5 when available (Lizard's default for agentic coding), else the newest Opus, else newest.
    public static func defaultAnthropicModel(from models: [RemoteModel]) -> String? {
        if models.contains(where: { $0.id == AnthropicProvider.defaultModel }) { return AnthropicProvider.defaultModel }
        let newest = models.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        return newest.first { $0.id.contains("opus") }?.id ?? newest.first?.id
    }

    // MARK: OpenAI

    public static func openAIModels(apiKey: String) async throws -> [RemoteModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await fetch(request)
        let data = (json["data"] as? [[String: Any]]) ?? []
        return data.compactMap { entry -> RemoteModel? in
            guard let id = entry["id"] as? String, isOpenAIChatModel(id) else { return nil }
            let created = (entry["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return RemoteModel(id: id, name: id, created: created)
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// Chat/agent-capable models only (no audio, image, embedding, moderation, realtime…).
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let excluded = ["audio", "realtime", "tts", "whisper", "transcribe", "embedding", "moderation", "image", "dall-e", "davinci", "babbage", "search", "instruct", "computer-use"]
        guard id.hasPrefix("gpt-") || id.hasPrefix("o") || id.contains("codex") else { return false }
        return !excluded.contains { id.contains($0) }
    }

    /// Newest flagship GPT (not mini/nano), preferring a dated-free alias.
    public static func defaultOpenAIModel(from models: [RemoteModel]) -> String? {
        let flagship = models.filter { $0.id.hasPrefix("gpt-") && !$0.id.contains("mini") && !$0.id.contains("nano") }
        let aliases = flagship.filter { $0.id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil }
        return (aliases.first ?? flagship.first ?? models.first)?.id
    }

    // MARK: OpenRouter

    /// Verifies the key, then lists models that support tool calling (the agent needs tools).
    public static func openRouterModels(apiKey: String) async throws -> [RemoteModel] {
        var check = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        check.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await fetch(check)
        return try await openRouterCatalog()
    }

    /// OpenRouter's public list (no key needed), tool-capable models only, with prices and
    /// free models marked — free first, then newest.
    public static func openRouterCatalog() async throws -> [RemoteModel] {
        let json = try await fetch(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!))
        return parseOpenRouter(json)
    }

    static func parseOpenRouter(_ json: [String: Any]) -> [RemoteModel] {
        let data = (json["data"] as? [[String: Any]]) ?? []
        let models = data.compactMap { entry -> RemoteModel? in
            guard let id = entry["id"] as? String, !id.hasSuffix(":batch"),
                (entry["supported_parameters"] as? [String])?.contains("tools") == true
            else { return nil }
            let created = (entry["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let pricing = entry["pricing"] as? [String: Any]
            // Prices come per token as strings ("0.000003"); shown per million tokens.
            func perMillion(_ key: String) -> Double? {
                (pricing?[key] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            }
            let input = perMillion("prompt")
            let output = perMillion("completion")
            let free = id.hasSuffix(":free") || (input == 0 && output == 0)
            return RemoteModel(id: id, name: entry["name"] as? String ?? id, created: created, isFree: free,
                               inputPrice: input, outputPrice: output, contextLength: (entry["context_length"] as? NSNumber)?.intValue)
        }
        return sortedFreeFirst(models)
    }

    /// Free models first, then the rest; newest first within each.
    public static func sortedFreeFirst(_ models: [RemoteModel]) -> [RemoteModel] {
        models.sorted {
            if $0.isFree != $1.isFree { return $0.isFree }
            return ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
        }
    }

    /// A handful of well-known models worth showing first (the newest of each family offered).
    public static func popularOpenRouterModels(from models: [RemoteModel]) -> [RemoteModel] {
        let families = ["anthropic/claude-opus", "anthropic/claude-sonnet", "openai/gpt-5", "google/gemini", "x-ai/grok", "deepseek/deepseek", "qwen/qwen3-coder", "moonshotai/kimi"]
        return families.compactMap { prefix in
            models.filter { $0.id.hasPrefix(prefix) && !$0.isFree }
                .max { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }
    }

    /// Claude Opus 5.5 when offered, else the newest Claude Opus, else the newest model.
    public static func defaultOpenRouterModel(from models: [RemoteModel]) -> String? {
        if models.contains(where: { $0.id == ProviderSettings.defaultOpenRouterModel }) { return ProviderSettings.defaultOpenRouterModel }
        let newest = models.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        return newest.first { $0.id.hasPrefix("anthropic/claude-opus") }?.id ?? newest.first?.id
    }

    // MARK: Ollama

    public static func ollamaModels(baseURL: String) async throws -> [RemoteModel] {
        guard var components = URLComponents(string: baseURL) else { throw DirectoryError.unreachable("invalid URL") }
        components.path = "/api/tags"
        guard let url = components.url else { throw DirectoryError.unreachable("invalid URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let json = try await fetch(request)
        return ((json["models"] as? [[String: Any]]) ?? []).compactMap { entry in
            (entry["name"] as? String).map { RemoteModel(id: $0, name: $0, created: nil) }
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DirectoryError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DirectoryError.http(status, String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
