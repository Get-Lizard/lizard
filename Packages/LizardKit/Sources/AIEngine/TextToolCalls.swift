import Foundation

/// Recovers tool calls that a model wrote as text instead of through the structured channel.
/// Handles the two common formats:
/// - XML function (Qwen3-Coder, Qwen3.5+, Nemotron):
///   `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
/// - JSON (Hermes/Qwen2.5): `<tool_call>{"name": "...", "arguments": {...}}</tool_call>`
public enum TextToolCalls {
    public struct Extraction: Sendable {
        /// The text with tool-call markup removed.
        public let text: String
        public let calls: [ToolCall]
    }

    public static func extract(from text: String) -> Extraction {
        guard text.contains("<tool_call>") || text.contains("<function=") else {
            return Extraction(text: text, calls: [])
        }
        var calls: [ToolCall] = []
        var cleaned = text

        // XML function format; the closing </tool_call> may be missing at the end of output.
        let xmlBlock = /(?:<tool_call>\s*)?<function=([\w.\-]+)>([\s\S]*?)<\/function>(?:\s*<\/tool_call>)?/
        for match in text.matches(of: xmlBlock) {
            var arguments: [String: JSONValue] = [:]
            for parameter in String(match.2).matches(of: /<parameter=([\w.\-]+)>([\s\S]*?)<\/parameter>/) {
                arguments[String(parameter.1)] = value(String(parameter.2))
            }
            calls.append(ToolCall(id: "call_\(UUID().uuidString.prefix(8))", name: String(match.1), arguments: .object(arguments)))
            cleaned = cleaned.replacingOccurrences(of: String(text[match.range]), with: "")
        }

        // JSON format.
        if calls.isEmpty {
            for match in text.matches(of: /<tool_call>\s*(\{[\s\S]*?\})\s*<\/tool_call>/) {
                guard let json = try? JSONValue.parse(String(match.1)), let name = json["name"]?.stringValue else { continue }
                var arguments = json["arguments"] ?? json["parameters"] ?? [:]
                if let string = arguments.stringValue, let parsed = try? JSONValue.parse(string) { arguments = parsed }
                calls.append(ToolCall(id: "call_\(UUID().uuidString.prefix(8))", name: name, arguments: arguments))
                cleaned = cleaned.replacingOccurrences(of: String(text[match.range]), with: "")
            }
        }

        cleaned = cleaned.replacingOccurrences(of: "<tool_call>", with: "").replacingOccurrences(of: "</tool_call>", with: "")
        return Extraction(text: cleaned.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls)
    }

    /// Parameter values are raw text; numbers/booleans/objects are recovered when the whole value is JSON.
    static func value(_ raw: String) -> JSONValue {
        var text = raw
        if text.hasPrefix("\n") { text.removeFirst() }
        if text.hasSuffix("\n") { text.removeLast() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, "{[".contains(first) || ["true", "false", "null"].contains(trimmed) || Double(trimmed) != nil,
            let parsed = try? JSONValue.parse(trimmed)
        {
            return parsed
        }
        return .string(text)
    }
}
