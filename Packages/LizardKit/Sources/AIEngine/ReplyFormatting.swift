import Foundation

/// Keeps chat replies readable. Small on-device models sometimes answer a plain question with a
/// whole HTML page ("<!DOCTYPE html>…"); unless the person asked for code, that becomes text.
public enum ReplyFormatting {
    /// Words that mean the person wants code (so code in the reply is on purpose).
    static let codeWords = [
        "code", "html", "css", "javascript", "typescript", "swift", "python", "java", "kotlin", "rust", "golang", " go ", "ruby", "php",
        "sql", "bash", "shell", "zsh", "terminal", "command", "script", "regex", "json", "yaml", "xml", "markdown", "snippet",
        "function", "method", "class", "struct", "enum", "variable", "compile", "error", "exception", "stack trace", "bug", "debug",
        "api", "endpoint", "query", "git", "docker", "kubernetes", "kubectl", "npm", "brew", "install", "implement", "refactor",
        "program", "algorithm", "web page", "webpage", "website", "template", "markup", "<", "{", "()", "=>", "`",
    ]

    public static func wantsCode(_ question: String) -> Bool {
        let lower = " " + question.lowercased() + " "
        return codeWords.contains { lower.contains($0) }
    }

    /// The reply as the person should see it. Small on-device models like to tack code onto plain
    /// answers (or answer with a whole web page); unless code was asked for, that's removed.
    public static func tidy(_ reply: String, question: String) -> String {
        guard !wantsCode(question) else { return reply }
        if looksLikeHTMLDocument(reply) { return markdown(fromHTML: reply) }
        return withoutUnaskedCode(reply)
    }

    /// Drops fenced code blocks (finished or still streaming) when the words around them already
    /// answer. A reply that is only code is left alone.
    static func withoutUnaskedCode(_ reply: String) -> String {
        guard reply.contains("```") else { return reply }
        var prose: [String] = []
        var inFence = false
        for line in reply.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { prose.append(line) }
        }
        let text = prose.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 20 ? text : reply
    }

    static func looksLikeHTMLDocument(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<!doctype html") || lower.contains("<html") || (lower.contains("<body") && lower.contains("</"))
            || lower.range(of: #"<(p|h[1-6]|div|ul|li|br)\b[^>]*>"#, options: .regularExpression) != nil && lower.filter { $0 == "<" }.count >= 4
    }

    /// Headings, paragraphs and list items become Markdown; everything else is dropped.
    static func markdown(fromHTML html: String) -> String {
        var text = html
        // Code fences around the page.
        text = text.replacingOccurrences(of: #"```[a-zA-Z]*"#, with: "", options: .regularExpression)
        // Head, styles and scripts carry no answer.
        for block in ["head", "style", "script"] {
            text = text.replacingOccurrences(of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        let rules: [(String, String)] = [
            (#"<h[1-3][^>]*>"#, "\n\n### "), (#"<h[4-6][^>]*>"#, "\n\n**"), (#"</h[4-6]>"#, "**\n\n"),
            (#"<li[^>]*>"#, "\n- "), (#"<br\s*/?>"#, "\n"), (#"</(p|div|h[1-3]|ul|ol|li)>"#, "\n"),
            (#"<(strong|b)>"#, "**"), (#"</(strong|b)>"#, "**"), (#"<(em|i)>"#, "_"), (#"</(em|i)>"#, "_"),
            (#"<!doctype[^>]*>"#, ""), (#"<[^>]+>"#, ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&deg;", "°")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
