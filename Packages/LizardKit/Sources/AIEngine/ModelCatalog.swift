import Foundation

/// Local models Lizard offers, with what they're good at and how much memory they need.
/// Fit is computed against the actual Mac (`gpuBudgetBytes`), so the list adapts to any machine.
public struct LocalModel: Sendable, Hashable, Identifiable {
    public enum Strength: String, Sendable, Hashable, CaseIterable {
        case coding = "Coding"
        case reasoning = "Reasoning"
        case fast = "Fast"
        case general = "General"
        case multilingual = "Multilingual"
    }

    public enum Availability: Sendable, Hashable {
        case mlx
        /// Can't run in the built-in MLX engine; offered through another route.
        case unavailable(reason: String, alternative: String?)
    }

    public let id: String
    public let name: String
    public let family: String
    public let parameters: String
    public let downloadGB: Double
    public let strengths: [Strength]
    public let blurb: String
    /// Higher = better output quality (used to recommend the best model that fits).
    public let quality: Int
    public let availability: Availability

    /// Unified memory needed while running: weights + KV cache/activations headroom.
    public var requiredGB: Double { downloadGB * 1.15 + 1.5 }

    /// 1–5 for non-experts.
    public var qualityStars: Int {
        switch quality {
        case 92...: 5
        case 84..<92: 4
        case 74..<84: 3
        case 60..<74: 2
        default: 1
        }
    }

    /// 1–5 for non-experts: smaller (or mixture-of-experts) models answer faster.
    public var speedStars: Int {
        let isMoE = parameters.contains("active")
        let effectiveGB = isMoE ? downloadGB / 4 : downloadGB
        switch effectiveGB {
        case ..<3: return 5
        case ..<5.5: return 4
        case ..<9: return 3
        case ..<14: return 2
        default: return 1
        }
    }

    /// One plain-language sentence about what this model is like to use.
    public var plainDescription: String {
        switch (qualityStars, speedStars) {
        case (5, _): "The smartest option: best answers, needs a big Mac."
        case (4, 4...): "Smart and quick, a great everyday choice."
        case (4, _): "Very capable. Explains code and reasons well."
        case (3, 4...): "Quick and dependable for summaries and rewrites."
        case (3, _): "Good for most quick jobs."
        default: "Light and fast. One-line summaries on smaller Macs."
        }
    }
}

public enum ModelFit: Int, Sendable, Comparable {
    case great, good, tight, tooLarge

    public static func < (lhs: ModelFit, rhs: ModelFit) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .great: "Runs great on this Mac"
        case .good: "Runs well on this Mac"
        case .tight: "Tight fit, other apps may slow down"
        case .tooLarge: "Too large for this Mac"
        }
    }
}

public enum ModelCatalog {
    /// Launcher jobs are short (summaries, rewrites, quick answers), so the list favours small,
    /// fast models; bigger ones are there for people who want a stronger local chat.
    public static let all: [LocalModel] = [
        LocalModel(
            id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", family: "Qwen", parameters: "1.7B", downloadGB: 1.0,
            strengths: [.fast], blurb: "Tiny and instant. Fine for one-line summaries on 8–16 GB Macs.", quality: 52, availability: .mlx),
        LocalModel(
            id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B", family: "Qwen", parameters: "4B", downloadGB: 2.3,
            strengths: [.fast, .general], blurb: "The sweet spot for a launcher: quick, good summaries and rewrites.", quality: 66, availability: .mlx),
        LocalModel(
            id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", family: "Qwen", parameters: "8B", downloadGB: 4.6,
            strengths: [.general, .coding, .fast], blurb: "Stronger answers and code explanations; still light.", quality: 76, availability: .mlx),
        LocalModel(
            id: "mlx-community/Qwen3.5-9B-4bit", name: "Qwen3.5 9B", family: "Qwen", parameters: "9B", downloadGB: 6.0,
            strengths: [.coding, .general], blurb: "Newer-generation small model, good at code and structure.", quality: 80, availability: .mlx),
        LocalModel(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", name: "DeepSeek-R1 Distill 7B", family: "DeepSeek", parameters: "7B", downloadGB: 4.3,
            strengths: [.reasoning], blurb: "Thinks step by step before answering. Slower, careful.", quality: 70, availability: .mlx),
        LocalModel(
            id: "mlx-community/Qwen3-14B-4bit", name: "Qwen3 14B", family: "Qwen", parameters: "14B", downloadGB: 8.3,
            strengths: [.coding, .reasoning], blurb: "Strong all-rounder chat for 24 GB+ Macs.", quality: 84, availability: .mlx),
        LocalModel(
            id: "mlx-community/gpt-oss-20b-MXFP4-Q8", name: "gpt-oss 20B", family: "OpenAI", parameters: "21B (3.6B active)", downloadGB: 12.1,
            strengths: [.reasoning, .general, .fast], blurb: "OpenAI's open-weight reasoning model.", quality: 85, availability: .mlx),
        LocalModel(
            id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", name: "Qwen3-Coder 30B", family: "Qwen", parameters: "30B (3B active)", downloadGB: 17.2,
            strengths: [.coding, .fast], blurb: "Best local coding answers; mixture-of-experts so it stays quick.", quality: 94, availability: .mlx),
    ]

    /// The default for launcher jobs: Qwen3 4B, or 1.7B on Macs with 16 GB or less.
    /// `budgetBytes` nil → this Mac's memory.
    public static func launcherDefault(budgetBytes: UInt64?) -> LocalModel {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let small = budgetBytes.map { Double($0) / 1_073_741_824 < 11 } ?? (memoryGB <= 16)
        return model(id: small ? "mlx-community/Qwen3-1.7B-4bit" : "mlx-community/Qwen3-4B-4bit")!
    }

    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    public static func fit(_ model: LocalModel, budgetBytes: UInt64) -> ModelFit {
        let budget = Double(budgetBytes) / 1_073_741_824
        let ratio = model.requiredGB / budget
        switch ratio {
        case ..<0.55: return .great
        case ..<0.8: return .good
        case ..<1.0: return .tight
        default: return .tooLarge
        }
    }

    /// The few choices a non-expert should see.
    public struct SimplePicks: Sendable {
        public let best: LocalModel
        /// Noticeably lighter/faster alternative, if any.
        public let lighter: LocalModel?
        /// Higher quality but a tight fit (may slow other apps), if any.
        public let smarter: LocalModel?
    }

    public static func simplePicks(budgetBytes: UInt64) -> SimplePicks? {
        let runnable = all.filter { if case .mlx = $0.availability { true } else { false } }
        guard let best = recommended(budgetBytes: budgetBytes) ?? runnable.min(by: { $0.downloadGB < $1.downloadGB }) else { return nil }
        let lighter = runnable
            .filter { $0.id != best.id && $0.downloadGB <= best.downloadGB * 0.7 && $0.quality >= 60 && fit($0, budgetBytes: budgetBytes) <= .good }
            .max { $0.quality < $1.quality }
        let smarter = runnable
            .filter { $0.quality > best.quality && fit($0, budgetBytes: budgetBytes) == .tight }
            .max { $0.quality < $1.quality }
        return SimplePicks(best: best, lighter: lighter, smarter: smarter)
    }

    /// Best-quality runnable model that fits comfortably (great/good) on this machine.
    public static func recommended(budgetBytes: UInt64) -> LocalModel? {
        all.filter { if case .mlx = $0.availability { true } else { false } }
            .filter { fit($0, budgetBytes: budgetBytes) <= .good }
            .max { $0.quality < $1.quality }
    }
}
