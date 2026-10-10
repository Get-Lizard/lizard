import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user, assistant, tool
}

public struct ToolCall: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Provider-native content that must be replayed unchanged on the next request to the same
/// provider (for example Anthropic thinking blocks with signatures, or fallback blocks).
public struct ProviderContent: Sendable, Codable, Hashable {
    public let providerID: String
    public let blocks: JSONValue

    public init(providerID: String, blocks: JSONValue) {
        self.providerID = providerID
        self.blocks = blocks
    }
}

/// An image the user attached (screenshot, mockup…), already downscaled for upload.
public struct ImageAttachment: Sendable, Codable, Hashable {
    public var name: String
    /// `image/png` or `image/jpeg`.
    public var mediaType: String
    public var data: Data

    public init(name: String, mediaType: String, data: Data) {
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }

    public var base64: String { data.base64EncodedString() }
    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

public struct ChatMessage: Sendable, Codable, Identifiable, Hashable {
    public var id = UUID()
    public var role: ChatRole
    public var text: String
    public var toolCalls: [ToolCall]
    /// For `.tool` messages: the call this message answers.
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool
    public var providerContent: ProviderContent?
    /// Images on a user message (optional so older saved histories still decode).
    public var images: [ImageAttachment]?
    /// Injected by the harness in the user role (build results, nudges), not typed by the user.
    public var isHarness: Bool?

    public init(
        role: ChatRole, text: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
        toolName: String? = nil, isError: Bool = false, providerContent: ProviderContent? = nil
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.providerContent = providerContent
    }

    public static func user(_ text: String, images: [ImageAttachment] = []) -> ChatMessage {
        var message = ChatMessage(role: .user, text: text)
        if !images.isEmpty { message.images = images }
        return message
    }

    public static func toolResult(for call: ToolCall, output: String, isError: Bool) -> ChatMessage {
        ChatMessage(role: .tool, text: output, toolCallID: call.id, toolName: call.name, isError: isError)
    }
}

public struct ToolDefinition: Sendable, Hashable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ChatRequest: Sendable {
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var maxTokens: Int
    /// Reasoning models on the Mac: false skips the hidden reasoning pass (Qwen3's `enable_thinking`).
    /// nil leaves the model's default. Cloud providers ignore it.
    public var thinking: Bool?

    public init(system: String, messages: [ChatMessage], tools: [ToolDefinition] = [], maxTokens: Int = 32_000, thinking: Bool? = nil) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal(String?)
    case other(String)

    init(apiValue: String?) {
        switch apiValue {
        case nil, "end_turn", "stop", "stop_sequence": self = .endTurn
        case "tool_use", "tool_calls": self = .toolUse
        case "max_tokens", "length": self = .maxTokens
        case "refusal", "content_filter": self = .refusal(nil)
        case let other?: self = .other(other)
        }
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum ChatEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    /// The model tried to call a tool but its arguments could not be parsed.
    case invalidToolCall(id: String, name: String, raw: String)
    case usage(TokenUsage)
    /// Progress note (e.g. model download) to show the user.
    case status(String)
    case completed(StopReason, providerContent: ProviderContent?)
}

public protocol AIProvider: Sendable {
    /// Stable identity, used to decide whether provider-native content can be replayed.
    var id: String { get }
    var displayName: String { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    /// Whether the model can see images attached to user messages.
    var supportsImages: Bool { get }
    /// How many prompt tokens to aim for. Local models get a small budget (memory, speed and
    /// quality all degrade with long prompts); cloud models a large one.
    var contextTokens: Int { get }
}

extension AIProvider {
    public var supportsImages: Bool { false }
    public var contextTokens: Int { 150_000 }
}

public enum AIProviderError: Error, LocalizedError {
    case missingAPIKey(String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "No API key configured for \(provider)."
        case .http(402, let body) where body.contains("credit"):
            "Out of credit: the AI service needs more credit for this request. (HTTP 402: \(body.prefix(300)))"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(600))"
        case .invalidResponse(let detail): "Invalid response: \(detail)"
        case .unavailable(let detail): detail
        }
    }
}
