import Foundation

/// OpenCode Zen (opencode.ai): curated coding models behind an OpenAI-compatible endpoint.
/// Zen has no third-party OAuth, so "Sign in" opens opencode.ai/auth; Lizard picks the key up
/// from an existing `opencode auth login` (its auth.json) or from what the user pastes.
public enum OpenCodeZen {
    public static let baseURL = URL(string: "https://opencode.ai/zen/v1")!
    public static let signInPage = URL(string: "https://opencode.ai/auth")!
    /// Used when the user hasn't picked a model and the model list can't be read.
    public static let fallbackModel = "qwen3-coder"

    /// Where the OpenCode CLI keeps its logins (`$XDG_DATA_HOME/opencode/auth.json`).
    public static var cliAuthFile: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")
        return base.appending(path: "opencode/auth.json")
    }

    /// The Zen key from an OpenCode CLI login, if the user has one.
    public static func keyFromCLI() -> String? {
        guard let data = try? Data(contentsOf: cliAuthFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for name in ["opencode", "opencode-zen", "zen"] {
            if let entry = json[name] as? [String: Any], let key = entry["key"] as? String, !key.isEmpty { return key }
        }
        return nil
    }

    /// Model ids Zen offers to this key (OpenAI-style `/models`).
    public static func models(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]]
        else { throw AIProviderError.invalidResponse("OpenCode Zen model list") }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    public static func provider(apiKey: String, model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(baseURL: baseURL, model: model.isEmpty ? fallbackModel : model, apiKey: apiKey, label: "OpenCode Zen")
    }
}
