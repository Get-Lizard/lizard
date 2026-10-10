import Foundation

/// Something the launcher can find.
public struct SearchCandidate: Sendable {
    public let id: String
    public let title: String
    public let keywords: [String]
    /// Static boost (commands slightly above files, etc.).
    public let weight: Double

    public init(id: String, title: String, keywords: [String] = [], weight: Double = 0) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.weight = weight
    }
}

public struct RankedResult: Sendable, Equatable {
    public let id: String
    public let score: Double
    /// Match positions in the title (empty when a keyword matched).
    public let highlights: [Int]
}

/// Fuzzy match + frecency ranking.
public enum SearchEngine {
    public static func rank(_ candidates: [SearchCandidate], query: String, frecency: (String) -> Double, limit: Int = 50) -> [RankedResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return candidates
                .map { RankedResult(id: $0.id, score: frecency($0.id) + $0.weight, highlights: []) }
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .prefix(limit).map { $0 }
        }
        var results: [RankedResult] = []
        results.reserveCapacity(candidates.count / 4)
        for candidate in candidates {
            var best: (Double, [Int])?
            if let match = FuzzyMatcher.match(trimmed, in: candidate.title) { best = (match.score, match.indices) }
            for keyword in candidate.keywords {
                if let match = FuzzyMatcher.match(trimmed, in: keyword), match.score * 0.9 > (best?.0 ?? -.infinity) {
                    best = (match.score * 0.9, [])
                }
            }
            guard let (score, indices) = best else { continue }
            let boost = log1p(frecency(candidate.id)) * 2
            results.append(RankedResult(id: candidate.id, score: score + boost + candidate.weight, highlights: indices))
        }
        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
