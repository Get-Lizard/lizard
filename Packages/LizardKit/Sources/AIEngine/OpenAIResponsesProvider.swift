import Foundation

/// OpenAI via the Responses API (`POST /v1/responses`, SSE). Required for reasoning models with
/// function tools (Chat Completions rejects tools + reasoning_effort on them). Output items
/// (reasoning with encrypted content, function calls, messages) are replayed verbatim on the
/// next request, so the model keeps its reasoning across steps without server-side storage.
public struct OpenAIResponsesProvider: AIProvider {
    public let apiKey: String
    public let model: String
    public let effort: String
    public let baseURL: URL

    public var id: String { "openai:\(model)" }
    public var displayName: String { "OpenAI (\(model))" }
    public var supportsImages: Bool { true }

    public init(apiKey: String, model: String, effort: String = "medium", baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
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
                var parser = ResponsesStreamParser(providerID: providerID)
                do {
                    for try await payload in SSE.post(urlRequest) {
                        for event in try parser.consume(payload) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: ChatRequest) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 900
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = body(for: request).encodedData()
        return urlRequest
    }

    func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(request.system),
            "input": .array(Self.convert(request.messages, providerID: id)),
            "stream": true,
            "store": false,
            "include": ["reasoning.encrypted_content"],
            "reasoning": ["effort": .string(effort)],
            "max_output_tokens": .number(Double(request.maxTokens)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["type": "function", "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.inputSchema]
            })
        }
        return .object(body)
    }

    /// Provider-neutral transcript → Responses `input` items.
    static func convert(_ messages: [ChatMessage], providerID: String) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .user:
                if let images = message.images, !images.isEmpty {
                    let parts: [JSONValue] = [["type": "input_text", "text": .string(message.text)]]
                        + images.map { ["type": "input_image", "image_url": .string($0.dataURL)] }
                    items.append(["role": "user", "content": .array(parts)])
                } else {
                    items.append(["role": "user", "content": .string(message.text)])
                }
            case .assistant:
                if let native = message.providerContent, native.providerID == providerID, let output = native.blocks.arrayValue, !output.isEmpty {
                    items += output  // verbatim: reasoning (encrypted), function_call, message items
                } else {
                    if !message.text.isEmpty {
                        items.append(["role": "assistant", "content": .string(message.text)])
                    }
                    for call in message.toolCalls {
                        items.append([
                            "type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                            "arguments": .string(call.arguments.encodedString()),
                        ])
                    }
                }
            case .tool:
                items.append([
                    "type": "function_call_output", "call_id": .string(message.toolCallID ?? ""),
                    "output": .string(message.text.isEmpty ? "(empty)" : message.text),
                ])
            }
        }
        return items
    }
}

struct ResponsesStreamParser {
    let providerID: String
    private var outputItems: [Int: JSONValue] = [:]
    private var argumentBuffers: [String: String] = [:]  // item_id → arguments
    private var calls: [ToolCall] = []
    private var invalid: [(id: String, name: String, raw: String)] = []
    private var usage = TokenUsage()
    private var status = "completed"
    private var incompleteReason: String?

    init(providerID: String) {
        self.providerID = providerID
    }

    mutating func consume(_ payload: String) throws -> [ChatEvent] {
        guard let event = try? JSONValue.parse(payload), let type = event["type"]?.stringValue else { return [] }
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"]?.stringValue, !delta.isEmpty { return [.textDelta(delta)] }
        case "response.function_call_arguments.delta":
            if let itemID = event["item_id"]?.stringValue {
                argumentBuffers[itemID, default: ""] += event["delta"]?.stringValue ?? ""
            }
        case "response.output_item.done":
            guard let item = event["item"] else { break }
            let index = event["output_index"]?.intValue ?? outputItems.count
            outputItems[index] = item
            if item["type"]?.stringValue == "function_call" {
                let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "call_\(UUID().uuidString.prefix(8))"
                let name = item["name"]?.stringValue ?? ""
                let raw = item["arguments"]?.stringValue ?? argumentBuffers[item["id"]?.stringValue ?? ""] ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    calls.append(ToolCall(id: callID, name: name, arguments: [:]))
                } else if let parsed = try? JSONValue.parse(trimmed), parsed.objectValue != nil {
                    calls.append(ToolCall(id: callID, name: name, arguments: parsed))
                } else {
                    invalid.append((callID, name, raw))
                }
            }
        case "response.completed", "response.incomplete":
            let response = event["response"]
            status = response?["status"]?.stringValue ?? (type == "response.completed" ? "completed" : "incomplete")
            incompleteReason = response?["incomplete_details"]?["reason"]?.stringValue
            if let input = response?["usage"]?["input_tokens"]?.intValue { usage.inputTokens = input }
            if let output = response?["usage"]?["output_tokens"]?.intValue { usage.outputTokens = output }
        case "response.failed":
            let message = event["response"]?["error"]?["message"]?.stringValue ?? "The response failed."
            throw AIProviderError.invalidResponse(message)
        case "error":
            throw AIProviderError.invalidResponse(event["message"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? payload)
        default:
            break
        }
        return []
    }

    mutating func finish() -> [ChatEvent] {
        var events: [ChatEvent] = [.usage(usage)]
        let truncated = status == "incomplete" && incompleteReason == "max_output_tokens"
        if truncated {
            events += calls.map { ChatEvent.invalidToolCall(id: $0.id, name: $0.name, raw: $0.arguments.encodedString()) }
        } else {
            events += calls.map(ChatEvent.toolCall)
        }
        events += invalid.map { ChatEvent.invalidToolCall(id: $0.id, name: $0.name, raw: $0.raw) }
        let stop: StopReason = truncated ? .maxTokens : (calls.isEmpty ? .endTurn : .toolUse)
        let ordered = outputItems.keys.sorted().compactMap { outputItems[$0] }
        events.append(.completed(stop, providerContent: ProviderContent(providerID: providerID, blocks: .array(ordered))))
        return events
    }
}
