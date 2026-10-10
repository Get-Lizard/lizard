import Foundation

/// Splits documents into passages of roughly `targetCharacters`, on paragraph boundaries, keeping
/// the Markdown heading each passage sits under, with a little overlap so context isn't cut off.
public enum TextChunker {
    public static func chunks(for text: String, targetCharacters: Int = 900, overlap: Int = 150) -> [KnowledgeChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= targetCharacters { return [KnowledgeChunk(ordinal: 0, text: trimmed, heading: firstHeading(in: trimmed))] }

        var paragraphs: [(heading: String?, text: String)] = []
        var heading: String?
        var current = ""
        var inFence = false
        for line in trimmed.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") { inFence.toggle() }
            if !inFence, stripped.hasPrefix("#"), let space = stripped.firstIndex(of: " "), stripped[..<space].allSatisfy({ $0 == "#" }) {
                if !current.isEmpty { paragraphs.append((heading, current)); current = "" }
                heading = String(stripped[stripped.index(after: space)...])
                continue
            }
            if !inFence, stripped.isEmpty {
                if !current.isEmpty { paragraphs.append((heading, current)); current = "" }
                continue
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { paragraphs.append((heading, current)) }

        var result: [KnowledgeChunk] = []
        var buffer = ""
        var bufferHeading: String?
        /// Whether the buffer holds text not yet emitted (beyond the carried-over overlap).
        var hasNew = false
        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, hasNew else { return }
            result.append(KnowledgeChunk(ordinal: result.count, text: text, heading: bufferHeading))
            buffer = overlap > 0 ? String(text.suffix(overlap)) : ""
            hasNew = false
        }
        for paragraph in paragraphs {
            // A new section starts a new passage (no overlap across headings).
            if paragraph.heading != bufferHeading, !buffer.isEmpty {
                flush()
                buffer = ""
            }
            bufferHeading = paragraph.heading
            if paragraph.text.count > targetCharacters {
                // Very long paragraph (code, logs): hard-split on line or character boundaries.
                for piece in split(paragraph.text, size: targetCharacters) {
                    buffer = piece
                    hasNew = true
                    flush()
                }
                continue
            }
            if buffer.count + paragraph.text.count > targetCharacters { flush() }
            buffer += buffer.isEmpty ? paragraph.text : "\n\n" + paragraph.text
            hasNew = true
        }
        flush()
        return result
    }

    static func split(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > size, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            if line.count > size {
                var rest = Substring(line)
                while rest.count > size {
                    pieces.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current = String(rest)
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func firstHeading(in text: String) -> String? {
        for line in text.split(separator: "\n").prefix(3) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("# ") { return String(stripped.dropFirst(2)) }
        }
        return nil
    }
}
