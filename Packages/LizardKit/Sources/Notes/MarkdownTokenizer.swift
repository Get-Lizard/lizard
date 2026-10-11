import Foundation

/// Line-based Markdown tokenizer for live syntax highlighting in the notes editor.
/// Ranges are UTF-16 (`NSRange`) so they apply directly to `NSTextStorage`.
public enum MarkdownTokenizer {
    public enum Kind: Sendable, Equatable {
        case heading(Int)
        case bold, italic, inlineCode, link, listMarker, blockquote, taskOpen, taskDone, rule
        case fence, codeBlock
    }

    public struct Token: Sendable, Equatable {
        public let kind: Kind
        public let range: NSRange
    }

    /// Tokens for the whole text.
    public static func tokenize(_ text: String) -> [Token] {
        tokenize(text, in: NSRange(location: 0, length: (text as NSString).length), startsInFence: false)
    }

    /// Whether the line starting at `location` is inside a ``` code fence.
    public static func fenceState(_ text: String, upTo location: Int) -> Bool {
        let ns = text as NSString
        var inside = false
        var position = 0
        while position < min(location, ns.length) {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            if ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("```") { inside.toggle() }
            position = NSMaxRange(line)
        }
        return inside
    }

    /// Tokens for the lines covering `range` (for re-highlighting just the edited paragraph).
    public static func tokenize(_ text: String, in range: NSRange, startsInFence: Bool) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var inFence = startsInFence
        var position = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        let end = NSMaxRange(range)
        while position < ns.length, position <= end {
            let lineRange = ns.lineRange(for: NSRange(location: position, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = NSRange(location: lineRange.location, length: (line.trimmingCharacters(in: .newlines) as NSString).length)
            if trimmed.hasPrefix("```") {
                tokens.append(Token(kind: .fence, range: content))
                inFence.toggle()
            } else if inFence {
                tokens.append(Token(kind: .codeBlock, range: content))
            } else {
                tokens += lineTokens(line, at: lineRange.location)
            }
            position = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        return tokens
    }

    static func lineTokens(_ line: String, at offset: Int) -> [Token] {
        let ns = line as NSString
        let body = NSRange(location: offset, length: (line.trimmingCharacters(in: .newlines) as NSString).length)
        var tokens: [Token] = []
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(leading)

        if let hashes = rest.firstIndex(where: { $0 != "#" }), rest.hasPrefix("#") {
            let level = rest.distance(from: rest.startIndex, to: hashes)
            if level <= 6, rest[hashes] == " " { return [Token(kind: .heading(level), range: body)] }
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["---", "***", "___"].contains(trimmed) { return [Token(kind: .rule, range: body)] }
        if rest.hasPrefix(">") { tokens.append(Token(kind: .blockquote, range: body)) }
        for marker in ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "* [x] ", "* [X] "] where rest.hasPrefix(marker) {
            tokens.append(Token(kind: .listMarker, range: NSRange(location: offset + leading, length: 2)))
            tokens.append(Token(kind: marker.contains("[ ]") ? .taskOpen : .taskDone, range: NSRange(location: offset + leading + 2, length: 3)))
            if !marker.contains("[ ]") {
                tokens.append(Token(kind: .taskDone, range: NSRange(location: offset + leading + 6, length: max(0, body.length - leading - 6))))
            }
            return tokens + inlineTokens(ns, offset: offset)
        }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            tokens.append(Token(kind: .listMarker, range: NSRange(location: offset + leading, length: 1)))
        } else if let dot = rest.firstIndex(of: "."), rest[rest.startIndex..<dot].allSatisfy(\.isNumber), !rest[rest.startIndex..<dot].isEmpty {
            tokens.append(Token(kind: .listMarker, range: NSRange(location: offset + leading, length: rest.distance(from: rest.startIndex, to: dot) + 1)))
        }
        return tokens + inlineTokens(ns, offset: offset)
    }

    static let inlinePatterns: [(Kind, NSRegularExpression)] = [
        (.inlineCode, try! NSRegularExpression(pattern: "`[^`\\n]+`")),
        (.bold, try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)[^\\n]+?(?<=\\S)\\1")),
        (.italic, try! NSRegularExpression(pattern: "(?<![*_\\w])([*_])(?=\\S)[^*_\\n]+?(?<=\\S)\\1(?![*_\\w])")),
        (.link, try! NSRegularExpression(pattern: "\\[[^\\]\\n]+\\]\\([^)\\s]+\\)|https?://[^\\s)]+")),
    ]

    public static func inlineTokens(_ line: NSString, offset: Int) -> [Token] {
        var tokens: [Token] = []
        var code: [NSRange] = []
        for (kind, regex) in inlinePatterns {
            for match in regex.matches(in: line as String, range: NSRange(location: 0, length: line.length)) {
                // Nothing is formatted inside inline code.
                if kind != .inlineCode, code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                if kind == .inlineCode { code.append(match.range) }
                tokens.append(Token(kind: kind, range: NSRange(location: match.range.location + offset, length: match.range.length)))
            }
        }
        return tokens
    }
}
