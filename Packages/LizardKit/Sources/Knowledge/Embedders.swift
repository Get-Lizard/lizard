import Foundation
import NaturalLanguage

/// Turns text into vectors for semantic search.
public protocol Embedder: Sendable {
    /// Identifies the vector space; changing embedder re-indexes everything.
    var identifier: String { get }
    var displayName: String { get }
    /// Unit-length vectors, one per text.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}

/// Queries and passages are phrased differently for asymmetric models (e5, Qwen3-Embedding).
public enum EmbeddingKind: Sendable {
    case query, passage
}

public enum EmbedderError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// Apple's built-in English sentence embedding: no download, decent for English, the fallback
/// until the multilingual MLX model is downloaded.
public final class AppleSentenceEmbedder: Embedder, @unchecked Sendable {
    public let identifier = "apple.sentence.en.v1"
    public let displayName = "Apple sentence embedding (English)"
    private let lock = NSLock()
    private let embedding: NLEmbedding?

    public init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    public var isAvailable: Bool { embedding != nil }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        guard let embedding else { throw EmbedderError.unavailable("Apple's sentence embedding isn't available on this Mac.") }
        return lock.withLock {
            texts.map { text in
                // The model reads short text best; the start of a passage carries its topic.
                let vector = embedding.vector(for: String(text.prefix(1_000))) ?? []
                return VectorMath.normalized(vector.map(Float.init), dimension: embedding.dimension)
            }
        }
    }
}

public enum VectorMath {
    public static func normalized(_ vector: [Float], dimension: Int) -> [Float] {
        guard !vector.isEmpty else { return [Float](repeating: 0, count: dimension) }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    /// Dot product of unit vectors = cosine similarity.
    @inline(__always)
    public static func dot(_ a: UnsafeBufferPointer<Float>, _ b: [Float]) -> Float {
        var sum: Float = 0
        let count = min(a.count, b.count)
        for index in 0..<count { sum += a[index] * b[index] }
        return sum
    }
}
