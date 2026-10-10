import Foundation

/// Claude via the Messages API over raw HTTP + SSE (there is no official Swift SDK).
public struct AnthropicProvider: AIProvider {
    public static let defaultModel = "claude-opus-5-5"

    public let apiKey: String
    public let model: String
    public let effort: String
    public let baseURL: URL

    public var id: String { "anthropic:\(model)" }
    public var displayName: String { "Claude (\(model))" }
    public var supportsImages: Bool { true }

    public init(
        apiKey: String, model: String = AnthropicProvider.defaultModel, effort: String = "high",
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let urlRequest = makeURLRequest(request)
        let providerID = id
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = AnthropicStreamParser(providerID: providerID)
                do {
                    for try await payload in SSE.post(urlRequest) {
                        for event in try parser.consume(payload) {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: ChatRequest) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallback, routed by refusal category.
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = body(for: request).encodedData()
        return urlRequest
    }

    func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "system": .string(request.system),
            "messages": .array(Self.convert(request.messages, providerID: id)),
            "output_config": ["effort": .string(effort)],
            "fallbacks": "default",
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                    "eager_input_streaming": true,
                ]
            })
        }
        return .object(body)
    }

    /// Converts the provider-neutral transcript into Messages API turns. Consecutive tool
    /// results collapse into one user turn, as the API expects.
    static func convert(_ messages: [ChatMessage], providerID: String) -> [JSONValue] {
        var turns: [(role: String, blocks: [JSONValue])] = []

        func append(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append((role, blocks))
            }
        }

        for message in messages {
            switch message.role {
            case .user:
                // Images first, then the text (Anthropic's recommended order).
                let images: [JSONValue] = (message.images ?? []).map { image in
                    ["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)]]
                }
                append("user", images + [["type": "text", "text": .string(message.text)]])
            case .assistant:
                if let native = message.providerContent, native.providerID == providerID,
                    let blocks = native.blocks.arrayValue, !blocks.isEmpty
                {
                    append("assistant", blocks)
                } else {
                    var blocks: [JSONValue] = []
                    if !message.text.isEmpty {
                        blocks.append(["type": "text", "text": .string(message.text)])
                    }
                    for call in message.toolCalls {
                        blocks.append([
                            "type": "tool_use", "id": .string(call.id), "name": .string(call.name),
                            "input": call.arguments.objectValue != nil ? call.arguments : [:],
                        ])
                    }
                    if blocks.isEmpty { blocks.append(["type": "text", "text": "(no output)"]) }
                    append("assistant", blocks)
                }
            case .tool:
                var block: [String: JSONValue] = [
                    "type": "tool_result",
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text.isEmpty ? "(empty)" : message.text),
                ]
                if message.isError { block["is_error"] = true }
                append("user", [.object(block)])
            }
        }
        return turns.map { ["role": .string($0.role), "content": .array($0.blocks)] }
    }
}

/// Incremental parser for Messages API stream events. Rebuilds every content block so the
/// assistant turn can be replayed verbatim (thinking signatures, fallback blocks, ...).
struct AnthropicStreamParser {
    let providerID: String
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var stopReason: StopReason = .endTurn
    private var refusalCategory: String?
    private var toolCalls: [ToolCall] = []
    private var invalidCalls: [(id: String, name: String, raw: String)] = []
    private var usage = TokenUsage()

    init(providerID: String) {
        self.providerID = providerID
    }

    mutating func consume(_ payload: String) throws -> [ChatEvent] {
        guard let event = try? JSONValue.parse(payload), let type = event["type"]?.stringValue else { return [] }
        switch type {
        case "message_start":
            if let input = event["message"]?["usage"]?["input_tokens"]?.intValue {
                usage.inputTokens = input
            }
        case "content_block_start":
            guard let index = event["index"]?.intValue, let block = event["content_block"]?.objectValue else { break }
            blocks[index] = block
            if block["type"]?.stringValue == "tool_use" { partialJSON[index] = "" }
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                return [.textDelta(text)]
            }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"] else { break }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                appendString(text, key: "text", index: index)
                return [.textDelta(text)]
            case "thinking_delta":
                appendString(delta["thinking"]?.stringValue ?? "", key: "thinking", index: index)
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"]?.intValue, let block = blocks[index],
                block["type"]?.stringValue == "tool_use"
            else { break }
            let id = block["id"]?.stringValue ?? UUID().uuidString
            let name = block["name"]?.stringValue ?? ""
            let raw = partialJSON[index] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Eager input streaming: parse strictly; an unparseable input is never executed.
            if trimmed.isEmpty {
                blocks[index]?["input"] = [:]
                toolCalls.append(ToolCall(id: id, name: name, arguments: [:]))
            } else if let parsed = try? JSONValue.parse(trimmed), parsed.objectValue != nil {
                blocks[index]?["input"] = parsed
                toolCalls.append(ToolCall(id: id, name: name, arguments: parsed))
            } else {
                blocks[index]?["input"] = [:]
                invalidCalls.append((id, name, raw))
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue {
                stopReason = StopReason(apiValue: reason)
                if case .refusal = stopReason {
                    refusalCategory = event["delta"]?["stop_details"]?["category"]?.stringValue
                }
            }
            if let output = event["usage"]?["output_tokens"]?.intValue {
                usage.outputTokens = output
            }
        case "error":
            let message = event["error"]?["message"]?.stringValue ?? payload
            throw AIProviderError.invalidResponse(message)
        default:
            break
        }
        return []
    }

    /// Emits tool calls and the completion event once the stream ends.
    mutating func finish() -> [ChatEvent] {
        var events: [ChatEvent] = [.usage(usage)]
        if case .refusal = stopReason {
            stopReason = .refusal(refusalCategory)
        }
        switch stopReason {
        case .refusal, .maxTokens:
            // A cut-off turn may hold truncated tool input; never execute it.
            for call in toolCalls {
                events.append(.invalidToolCall(id: call.id, name: call.name, raw: call.arguments.encodedString()))
            }
        default:
            events += toolCalls.map(ChatEvent.toolCall)
        }
        events += invalidCalls.map { ChatEvent.invalidToolCall(id: $0.id, name: $0.name, raw: $0.raw) }
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }.map(JSONValue.object)
        events.append(.completed(stopReason, providerContent: ProviderContent(providerID: providerID, blocks: .array(ordered))))
        return events
    }

    private mutating func appendString(_ text: String, key: String, index: Int) {
        let existing = blocks[index]?[key]?.stringValue ?? ""
        blocks[index]?[key] = .string(existing + text)
    }
}
