import Foundation

/// "Ask your notes": a question answered only from retrieved passages, with numbered citations.
public enum AskNotes {
    /// How much retrieved text fits in a prompt (characters), by the answering model's budget.
    public static func contextBudget(promptTokens: Int) -> Int {
        // ~4 characters per token; leave room for the instructions, the question and the answer.
        max(2_000, min(24_000, (promptTokens - 1_200) * 3))
    }

    /// The passages that fit the budget, best first.
    public static func select(_ hits: [KnowledgeHit], budget: Int) -> [KnowledgeHit] {
        var used = 0
        var chosen: [KnowledgeHit] = []
        for hit in hits {
            let cost = hit.text.count + hit.title.count + 40
            if used + cost > budget, !chosen.isEmpty { break }
            chosen.append(hit)
            used += cost
        }
        return chosen
    }

    public static let system = """
        You answer questions about the user's own notes, work log, clipboard history and past AI chats, using only the numbered sources. \
        Write the answer in full sentences (1 to 6), then put the number of the source you used in square brackets at the end \
        of each sentence. Example: "You raised the connection pool from 10 to 50 [1]." \
        Keep code, commands and numbers exactly as written in the sources. \
        If the sources don't answer the question, say "Your notes don't say." and nothing else. \
        Answer in the language of the question.
        """

    /// Drops passages that are much weaker than the best one, so unrelated notes don't reach the prompt.
    public static func relevant(_ hits: [KnowledgeHit]) -> [KnowledgeHit] {
        guard let best = hits.map(\.similarity).max(), best > 0 else { return hits }
        return hits.filter { $0.similarity == 0 || $0.similarity >= best * 0.8 }
    }

    /// True when a reply is nothing but citation markers ("[1] [2]"), which small models sometimes produce.
    public static func isOnlyCitations(_ answer: String) -> Bool {
        let stripped = answer.replacingOccurrences(of: #"\[[\d,\s]*\]"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    public static func prompt(question: String, sources: [KnowledgeHit], now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = ["Today is \(formatter.string(from: now)).", "", "Sources:"]
        for (index, hit) in sources.enumerated() {
            let place = [hit.source.title, hit.title, hit.heading].compactMap { $0 }.joined(separator: " › ")
            lines.append("[\(index + 1)] \(place) (\(formatter.string(from: hit.modified)))")
            lines.append(hit.text)
            lines.append("")
        }
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    /// Source numbers cited in an answer ("[1]", "[2, 3]", "[1][4]"), in order of first use.
    public static func citations(in answer: String) -> [Int] {
        var seen: [Int] = []
        var index = answer.startIndex
        while let open = answer[index...].firstIndex(of: "[") {
            guard let close = answer[open...].firstIndex(of: "]") else { break }
            let inside = answer[answer.index(after: open)..<close]
            for part in inside.split(whereSeparator: { $0 == "," || $0 == " " }) {
                if let number = Int(part), number > 0, !seen.contains(number) { seen.append(number) }
            }
            index = answer.index(after: close)
        }
        return seen
    }
}
