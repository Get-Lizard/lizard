import Foundation

/// What Lizard reads from a note's text: front matter, tags, pin, and whether it's a snippet.
///
/// Front matter is optional and compatible with Obsidian & co.:
/// ```
/// ---
/// tags: [deploy, k8s]
/// pinned: true
/// ---
/// ```
/// Inline `#tags` anywhere outside code count too.
public struct NoteMetadata: Sendable, Hashable {
    public var tags: [String] = []
    public var pinned = false
    /// The text without front matter.
    public var body: String = ""
    /// Code blocks in order (language, code).
    public var codeBlocks: [CodeBlock] = []

    public struct CodeBlock: Sendable, Hashable {
        public let language: String?
        public let code: String
    }

    /// A snippet note: essentially one code block or one command — the launcher copies it on ↩.
    public var snippet: String? {
        let prose = Self.stripCode(body).split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#")
        }
        if codeBlocks.count == 1, prose.count <= 2 { return codeBlocks[0].code }
        // A note that is just a command: "$ kubectl get pods"
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("# ") }
        if codeBlocks.isEmpty, lines.count == 1, let line = lines.first, line.hasPrefix("$ ") || line.hasPrefix("> ") {
            return String(line.dropFirst(2))
        }
        return nil
    }

    /// Splits `---` front matter from the body. The closing delimiter must be a line of its own
    /// (so `----` or `---text` don't end it), and an empty block (`---\n---`) is recognised.
    static func frontMatter(of text: String) -> (header: [String], body: String)? {
        guard text.hasPrefix("---\n") else { return nil }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        guard let close = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (Array(lines[..<close]), body)
    }

    private static func cleanTag(_ raw: some StringProtocol) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'#")).lowercased()
    }

    public static func parse(_ text: String) -> NoteMetadata {
        var metadata = NoteMetadata()
        var body = text
        if let front = frontMatter(of: text) {
            body = front.body
            // The key whose YAML block list (`tags:` then `  - a`) is being read, if any.
            var listKey: String?
            for line in front.header {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- "), listKey == "tags" {
                    let tag = cleanTag(trimmed.dropFirst(2))
                    if !tag.isEmpty { metadata.tags.append(tag) }
                    continue
                }
                listKey = nil
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let key = parts.first?.lowercased() else { continue }
                let value = parts.count == 2 ? parts[1] : ""
                switch key {
                case "tags":
                    if value.isEmpty { listKey = "tags"; continue }
                    metadata.tags += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map(cleanTag).filter { !$0.isEmpty }
                case "pinned":
                    metadata.pinned = ["true", "yes", "1"].contains(value.lowercased())
                default:
                    break
                }
            }
        }
        metadata.body = body
        metadata.codeBlocks = codeBlocks(in: body)
        for tag in inlineTags(in: stripCode(body)) where !metadata.tags.contains(tag) { metadata.tags.append(tag) }
        return metadata
    }

    static func codeBlocks(in text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        var language: String?
        var lines: [String]?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let current = lines {
                    blocks.append(CodeBlock(language: language, code: current.joined(separator: "\n")))
                    lines = nil
                } else {
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    lines = []
                }
            } else if lines != nil {
                lines?.append(line)
            }
        }
        return blocks
    }

    static func stripCode(_ text: String) -> String {
        var result: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if !inFence { result.append(line.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)) }
        }
        return result.joined(separator: "\n")
    }

    /// `#tag` words (not headings, not URLs' fragments, not hex colours).
    static func inlineTags(in text: String) -> [String] {
        var tags: [String] = []
        let regex = try! NSRegularExpression(pattern: #"(?:^|\s)#([A-Za-z][\w/-]{0,40})"#)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) {
                let tag = text[range].lowercased()
                if !tags.contains(tag) { tags.append(tag) }
            }
        }
        return tags
    }

    /// Returns `text` with front matter rewritten to hold `tags` and `pinned` (other keys kept).
    public static func updating(_ text: String, tags: [String]? = nil, pinned: Bool? = nil) -> String {
        var header: [String] = []
        var body = text
        if let front = frontMatter(of: text) {
            header = front.header.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            body = front.body
        }
        func set(_ key: String, _ value: String?) {
            // Drop `key: …` and, for the YAML list form, the indented `- item` lines under it.
            var kept: [String] = []
            var dropping = false
            for line in header {
                if line.lowercased().hasPrefix(key + ":") { dropping = true; continue }
                if dropping, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") { continue }
                dropping = false
                kept.append(line)
            }
            header = kept
            if let value { header.append("\(key): \(value)") }
        }
        if let tags {
            // Inline #tags stay where they are; front matter holds the rest.
            let inline = Set(inlineTags(in: stripCode(body)))
            let front = tags.map { $0.lowercased() }.filter { !inline.contains($0) }
            set("tags", front.isEmpty ? nil : "[\(front.joined(separator: ", "))]")
        }
        if let pinned { set("pinned", pinned ? "true" : nil) }
        return header.isEmpty ? body + "\n" : "---\n" + header.joined(separator: "\n") + "\n---\n\n" + body + "\n"
    }
}
