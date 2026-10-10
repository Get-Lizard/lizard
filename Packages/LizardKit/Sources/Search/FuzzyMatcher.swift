import Foundation

/// Subsequence fuzzy matching tuned for launcher queries: prefix, word-start and camelCase hits
/// score high ("vsc" → "Visual Studio Code"), consecutive runs add up, gaps cost a little.
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public let score: Double
        /// Character offsets in the candidate that matched (for bold highlights).
        public let indices: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let original = Array(candidate)
        let haystack = Array(candidate.lowercased())
        guard haystack.count == original.count, needle.count <= haystack.count else { return nil }

        // Greedy pass preferring word starts, then a plain pass; keep the better.
        let best = [scan(needle, haystack, original, preferBoundaries: true), scan(needle, haystack, original, preferBoundaries: false)]
            .compactMap { $0 }
            .max { $0.score < $1.score }
        return best
    }

    private static func isBoundary(_ index: Int, _ original: [Character]) -> Bool {
        if index == 0 { return true }
        let previous = original[index - 1]
        let current = original[index]
        if previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/" { return true }
        return previous.isLowercase && current.isUppercase
    }

    private static func scan(_ needle: [Character], _ haystack: [Character], _ original: [Character], preferBoundaries: Bool) -> Match? {
        var indices: [Int] = []
        var position = 0
        for character in needle {
            var found: Int?
            if preferBoundaries {
                var probe = position
                while probe < haystack.count {
                    if haystack[probe] == character, isBoundary(probe, original) { found = probe; break }
                    probe += 1
                }
                // Continue a run if the next character matches right away.
                if let last = indices.last, last + 1 < haystack.count, haystack[last + 1] == character { found = last + 1 }
            }
            if found == nil {
                var probe = position
                while probe < haystack.count {
                    if haystack[probe] == character { found = probe; break }
                    probe += 1
                }
            }
            guard let index = found else { return nil }
            indices.append(index)
            position = index + 1
        }
        return Match(score: score(indices, original), indices: indices)
    }

    private static func score(_ indices: [Int], _ original: [Character]) -> Double {
        var total = 0.0
        var previous = -2
        for index in indices {
            var points = 1.0
            if index == 0 { points += 3 }
            else if isBoundary(index, original) { points += 2 }
            if index == previous + 1 { points += 1.5 }
            else if previous >= 0 { points -= min(1.0, Double(index - previous - 1) * 0.1) }
            total += points
            previous = index
        }
        // Shorter candidates and full-prefix matches win ties.
        total -= Double(original.count) * 0.01
        if indices == Array(0..<indices.count) { total += 2 }
        return total
    }
}
