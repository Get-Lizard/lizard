import Foundation
import Synchronization

/// "Auto · Free models" on OpenRouter: Lizard picks the strongest free, tool-capable models and
/// sends them as an OpenRouter fallback list (`models`), so a busy or rate-limited free model
/// (common) falls through to the next one. The ranking comes from OpenRouter's live catalogue
/// (cached across launches); a known-good list covers the very first run.
public enum OpenRouterFree {
    /// "Free only": stored in settings as the OpenRouter model.
    public static let autoModelID = "lizard/auto-free"
    /// "Auto": free models first, a paid model (OpenRouter's own router picks it) only when the
    /// free ones can't answer — and only if the account has credit.
    public static let autoMixedID = "lizard/auto"
    /// OpenRouter's paid auto-router (the last step of "Auto").
    public static let paidRouter = "openrouter/auto"

    public static func isAuto(_ id: String) -> Bool { id == autoModelID || id == autoMixedID }

    /// The OpenRouter request for an auto choice: first model + fallbacks (≤ 3 in total, the
    /// most any OpenRouter fallback API documents).
    public static func routing(for id: String) -> (model: String, fallbacks: [String])? {
        let list: [String]
        switch id {
        case autoModelID: list = best(3)
        case autoMixedID: list = best(2) + [paidRouter]
        default: return nil
        }
        return (list[0], Array(list.dropFirst()))
    }
    private static let storageKey = "Lizard.OpenRouterFreeModels"
    /// OpenRouter's own free router: always routes to some available free model. It's the last
    /// fallback (and the whole list before the catalogue has been fetched once — free model ids
    /// change every few weeks, so no ids are hard-coded).
    public static let router = "openrouter/free"
    /// Coding-strong families first (the rest by context size, then newest).
    static let preferredFamilies = ["qwen/qwen3", "poolside/laguna-s", "cohere/north", "nvidia/nemotron-3-ultra", "thinkingmachines/inkling:", "nvidia/nemotron-3-super",
                                    "google/gemma-4-31b", "moonshotai/kimi", "deepseek/", "z-ai/glm", "openai/gpt-oss", "qwen/", "google/gemma"]
    static let fallback: [String] = []

    private static let ranked = Mutex<[String]>(UserDefaults.standard.stringArray(forKey: storageKey) ?? fallback)

    /// The best free models, best first, ending with OpenRouter's free router as a safety net.
    public static func best(_ count: Int = 3) -> [String] {
        Array(ranked.withLock { $0 }.prefix(count - 1)) + [router]
    }

    /// Re-ranks from a fresh catalogue (free + tool-capable models only).
    public static func update(from models: [ModelDirectory.RemoteModel]) {
        let ordered = rank(models)
        guard !ordered.isEmpty else { return }
        ranked.withLock { $0 = ordered }
        UserDefaults.standard.set(ordered, forKey: storageKey)
    }

    static func rank(_ models: [ModelDirectory.RemoteModel]) -> [String] {
        let free = models.filter { $0.isFree && $0.id != router }
        func family(_ id: String) -> Int { preferredFamilies.firstIndex { id.hasPrefix($0) } ?? preferredFamilies.count }
        return free.sorted {
            let a = family($0.id), b = family($1.id)
            if a != b { return a < b }
            if ($0.contextLength ?? 0) != ($1.contextLength ?? 0) { return ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
            return ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
        }
        .map(\.id)
    }
}
