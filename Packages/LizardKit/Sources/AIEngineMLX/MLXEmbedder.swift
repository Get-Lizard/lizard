import Foundation
import HuggingFace
import Knowledge
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// On-device multilingual embeddings through MLX (Qwen3-Embedding-0.6B, 4-bit, ~350 MB).
/// Used by semantic search once downloaded; Apple's English sentence embedding covers until then.
public final class MLXEmbedder: Embedder, @unchecked Sendable {
    public static let modelID = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
    public static let downloadDescription = "Qwen3 Embedding 0.6B · about 350 MB · 100+ languages"

    public let identifier = "mlx.qwen3-embedding-0.6b-4bit.v1"
    public let displayName = "Qwen3 Embedding (on this Mac)"

    public init() {}

    public static var isDownloaded: Bool { ModelStore.isDownloaded(modelID) }

    /// Downloads (if needed) and loads the model, reporting progress 0…1.
    public static func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        _ = try await EmbedderHost.shared.container(progress: progress)
    }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await EmbedderHost.shared.container(progress: { _ in })
        // Qwen3-Embedding is asymmetric: queries carry a task instruction, passages don't.
        let inputs = texts.map { text in
            kind == .query
                ? "Instruct: Given a search query, retrieve the most relevant passages from the user's notes and logs\nQuery: \(text)"
                : text
        }
        // MLX isn't safe with overlapping GPU work; share the chat model's generation slot.
        await MLXModelHost.shared.acquireGenerationSlot()
        defer { Task { await MLXModelHost.shared.releaseGenerationSlot() } }
        await EmbedderHost.shared.touch()
        return await container.perform { context in
            let tokenizer = context.tokenizer
            let eos = tokenizer.eosTokenId ?? 0
            let encoded = inputs.map { input -> [Int] in
                var tokens = Array(tokenizer.encode(text: input, addSpecialTokens: true).prefix(511))
                if tokens.last != eos { tokens.append(eos) }
                return tokens
            }
            let length = encoded.map(\.count).max() ?? 1
            // Right-pad; the mask marks real tokens so last-token pooling picks the EOS position.
            let padded = stacked(encoded.map { MLXArray($0 + Array(repeating: eos, count: length - $0.count)) })
            let mask = stacked(encoded.map { MLXArray(Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: length - $0.count)) })
            let output = context.model(padded, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
            let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
            pooled.eval()
            return (0..<encoded.count).map { pooled[$0].asArray(Float.self) }
        }
    }
}

/// Keeps one embedding model loaded; unloads after 10 idle minutes.
actor EmbedderHost {
    static let shared = EmbedderHost()

    private var container: EmbedderModelContainer?
    private var loading: Task<EmbedderModelContainer, Error>?
    private var lastUsed = Date()
    private var idleTimer: Task<Void, Never>?

    func touch() {
        lastUsed = Date()
    }

    func container(progress: @escaping @Sendable (Double) -> Void) async throws -> EmbedderModelContainer {
        lastUsed = Date()
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task<EmbedderModelContainer, Error> {
            try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: EmbedderRegistry.qwen3_embedding
            ) { value in
                progress(value.fractionCompleted)
            }
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        container = loaded
        progress(1)
        scheduleIdleUnload()
        return loaded
    }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        idleTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Date().timeIntervalSince(lastUsed) > 600 {
                    container = nil
                    GPU.clearCache()
                    return
                }
            }
        }
    }
}
