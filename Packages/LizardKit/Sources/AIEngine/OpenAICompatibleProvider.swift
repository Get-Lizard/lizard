import Foundation

/// Any OpenAI-compatible chat completions endpoint: Ollama (`http://localhost:11434/v1`),
/// LM Studio, OpenAI, vLLM, ...
public struct OpenAICompatibleProvider: AIProvider {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let label: String
    /// OpenRouter fallback routing: tried in order when `model` is busy or unavailable.
    public let fallbackModels: [String]

    public var id: String { "openai-compatible:\(baseURL.absoluteString):\(model)" }
    public var displayName: String { fallbackModels.isEmpty ? "\(label) (\(model))" : "\(label) (free: \(model) + \(fallbackModels.count) backups)" }
    /// Ollama/LM Studio vision models, recognised by name.
    public var supportsImages: Bool { Self.isVisionModel(model) }
    /// Local servers (Ollama) default to small context windows; remote ones (OpenRouter) are large.
    public var contextTokens: Int {
        let host = baseURL.host() ?? ""
        return host == "localhost" || host == "127.0.0.1" ? 12_000 : 120_000
    }

    public static func isVisionModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return ["vl", "vision", "llava", "gemma3", "gemma4", "minicpm-v", "pixtral", "moondream", "bakllava", "gpt-4o", "gpt-5", "gpt-6", "claude", "gemini"].contains { name.contains($0) }
    }

    public init(baseURL: URL, model: String, apiKey: String? = nil, label: String = "OpenAI-compatible", fallbackModels: [String] = []) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.label = label
        self.fallbackModels = fallbackModels
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let urlRequest = makeURLRequest(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = OpenAIStreamParser()
                do {
                    for try await payload in SSE.post(urlRequest) {
                        if payload == "[DONE]" { break }
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
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "messages": .array([["role": "system", "content": .string(request.system)]] + Self.convert(request.messages)),
        ]
        if !fallbackModels.isEmpty {
            body["models"] = .array(([model] + fallbackModels).map { .string($0) })
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        urlRequest.httpBody = JSONValue.object(body).encodedData()
        return urlRequest
    }

    static func convert(_ messages: [ChatMessage]) -> [JSONValue] {
        messages.map { message in
            switch message.role {
            case .user:
                if let images = message.images, !images.isEmpty {
                    let parts: [JSONValue] = [["type": "text", "text": .string(message.text)]]
                        + images.map { ["type": "image_url", "image_url": ["url": .string($0.dataURL)]] }
                    return ["role": "user", "content": .array(parts)]
                }
                return ["role": "user", "content": .string(message.text)]
            case .assistant:
                var object: [String: JSONValue] = [
                    "role": "assistant",
                    "content": message.text.isEmpty ? .null : .string(message.text),
                ]
                if !message.toolCalls.isEmpty {
                    object["tool_calls"] = .array(message.toolCalls.map { call in
                        [
                            "id": .string(call.id), "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(call.arguments.encodedString())],
                        ]
                    })
                }
                return .object(object)
            case .tool:
                return [
                    "role": "tool", "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                ]
            }
        }
    }
}

struct OpenAIStreamParser {
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var usage = TokenUsage()

    mutating func consume(_ payload: String) throws -> [ChatEvent] {
        guard let chunk = try? JSONValue.parse(payload) else { return [] }
        if let error = chunk["error"] {
            throw AIProviderError.invalidResponse(error["message"]?.stringValue ?? error.encodedString())
        }
        if let prompt = chunk["usage"]?["prompt_tokens"]?.intValue { usage.inputTokens = prompt }
        if let completion = chunk["usage"]?["completion_tokens"]?.intValue { usage.outputTokens = completion }
        guard let choice = chunk["choices"]?.arrayValue?.first else { return [] }
        if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
        var events: [ChatEvent] = []
        if let content = choice["delta"]?["content"]?.stringValue, !content.isEmpty {
            events.append(.textDelta(content))
        }
        for (position, call) in (choice["delta"]?["tool_calls"]?.arrayValue ?? []).enumerated() {
            let index = call["index"]?.intValue ?? position
            var partial = calls[index] ?? PartialCall()
            if let id = call["id"]?.stringValue { partial.id = id }
            if let name = call["function"]?["name"]?.stringValue { partial.name += name }
            if let arguments = call["function"]?["arguments"] {
                // Most servers stream a string; some (Ollama variants) send an object.
                partial.arguments += arguments.stringValue ?? arguments.encodedString()
            }
            calls[index] = partial
        }
        return events
    }

    mutating func finish() -> [ChatEvent] {
        var events: [ChatEvent] = [.usage(usage)]
        for index in calls.keys.sorted() {
            guard let call = calls[index] else { continue }
            let id = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : call.id
            let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                events.append(.toolCall(ToolCall(id: id, name: call.name, arguments: [:])))
            } else if let parsed = try? JSONValue.parse(raw), parsed.objectValue != nil {
                events.append(.toolCall(ToolCall(id: id, name: call.name, arguments: parsed)))
            } else {
                events.append(.invalidToolCall(id: id, name: call.name, raw: raw))
            }
        }
        let reason: StopReason = calls.isEmpty ? StopReason(apiValue: finishReason) : .toolUse
        events.append(.completed(reason, providerContent: nil))
        return events
    }
}
