import Foundation

/// Text handling for voice typing: keeps the live transcript, removes fillers, and joins what you
/// said onto what's already in the field.
public struct DictationText: Sendable, Equatable {
    /// Finished segments (the recognizer won't change them any more).
    public private(set) var finalized = ""
    /// The segment still being recognized; replaced on every update.
    public private(set) var volatile = ""

    public init() {}

    public var current: String { Self.join(finalized, volatile) }

    public mutating func update(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces), right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// Hesitations people say but never mean to type.
    static let fillers = ["um", "umm", "uh", "uhh", "erm", "er", "ah", "hmm", "mm"]

    /// Fillers out, spacing and capitalization tidied. Keeps everything else as said.
    public static func clean(_ text: String) -> String {
        var result = text
        let pattern = #"(?i)(^|[\s,])(?:"# + fillers.joined(separator: "|") + #")(?=[\s,.!?]|$)[,]?"#
        result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase, text.first?.isUppercase == true {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// For a search field: no trailing period ("Open Safari." → "Open Safari").
    public static func forSearch(_ text: String) -> String {
        var result = clean(text)
        while let last = result.last, ".!".contains(last) { result.removeLast() }
        return result
    }

    /// What to insert after `before` (the text left of the caret): a space when needed, and a
    /// lowercase start mid-sentence.
    public static func insertion(_ text: String, after before: String) -> String {
        guard !text.isEmpty else { return text }
        guard let last = before.last else { return text }
        var result = text
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let midSentence = !trimmed.isEmpty && !".!?\n".contains(trimmed.last!)
        if midSentence, let first = result.first, first.isUppercase, result.dropFirst().first?.isLowercase ?? true,
            !result.hasPrefix("I ") {
            result = first.lowercased() + result.dropFirst()
        }
        return last.isWhitespace ? result : " " + result
    }
}
