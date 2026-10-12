@testable import AIEngine
import Foundation
import Testing

@Suite struct JSONValueTests {
    @Test func decodesEveryKindAndRoundTripsIntegers() throws {
        let value = try JSONValue.parse(#"{"a":1,"b":2.5,"c":true,"d":null,"e":["x"],"f":{"g":"h"}}"#)
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"] == .number(2.5))
        #expect(value["c"]?.boolValue == true)
        #expect(value["d"] == .null)
        #expect(value["e"]?.arrayValue == ["x"])
        #expect(value["f"]?["g"]?.stringValue == "h")
        // Whole numbers encode without ".0" (tool arguments are compared as text by some servers).
        #expect(value.encodedString() == #"{"a":1,"b":2.5,"c":true,"d":null,"e":["x"],"f":{"g":"h"}}"#)
    }

    @Test func intValueNeverTraps() {
        #expect(JSONValue.number(1e300).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(-3.9).intValue == -3)
        #expect(JSONValue.string("1").intValue == nil)
    }

    @Test func accessorsReturnNilForOtherKinds() {
        let value: JSONValue = "text"
        #expect(value["key"] == nil)
        #expect(value.boolValue == nil)
        #expect(value.arrayValue == nil)
        #expect(value.objectValue == nil)
        #expect(JSONValue.number(1).stringValue == nil)
    }

    @Test func literalsAndFoundationBridging() throws {
        let value: JSONValue = ["n": 3, "list": [true, nil], "s": "x"]
        let foundation = try #require(value.foundationValue as? [String: Any])
        #expect(foundation["n"] as? Int == 3)
        #expect((foundation["list"] as? [Any])?.last is NSNull)
        #expect(JSONValue.number(1.5).foundationValue as? Double == 1.5)
        let sendable = try #require(value.sendableValue as? [String: any Sendable])
        #expect(sendable["s"] as? String == "x")
    }

    @Test func decodesIntoTypes() throws {
        struct Args: Decodable { let path: String; let line: Int }
        let args = try JSONValue.object(["path": "a.swift", "line": 12]).decode(Args.self)
        #expect(args.path == "a.swift")
        #expect(args.line == 12)
    }

    @Test func prettyOutputIsSorted() {
        let pretty = JSONValue.object(["b": 1, "a": 2]).encodedString(pretty: true)
        #expect(pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
    }
}

@Suite struct SSETests {
    @Test func dataLines() {
        #expect(SSE.dataPayload(fromLine: "data: {\"a\":1}") == "{\"a\":1}")
        #expect(SSE.dataPayload(fromLine: "data:[DONE]") == "[DONE]")
        #expect(SSE.dataPayload(fromLine: "event: ping") == nil)
        #expect(SSE.dataPayload(fromLine: ": comment") == nil)
        #expect(SSE.dataPayload(fromLine: "") == nil)
    }

    @Test func transientFailures() {
        #expect(SSE.isTransient(status: 429))
        #expect(SSE.isTransient(status: 529))
        #expect(!SSE.isTransient(status: 400))
        #expect(!SSE.isTransient(status: 401))
        #expect(SSE.isTransient(URLError(.timedOut)))
        #expect(!SSE.isTransient(URLError(.badURL)))
        #expect(!SSE.isTransient(CocoaError(.fileNoSuchFile)))
    }

    @Test func retryAfterIsCapped() throws {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil, headerFields: value.map { ["Retry-After": $0] })!
        }
        #expect(SSE.retryAfter(response("2")) == .seconds(2))
        #expect(SSE.retryAfter(response("600")) == .seconds(20))
        #expect(SSE.retryAfter(response("soon")) == nil)
        #expect(SSE.retryAfter(response(nil)) == nil)
    }
}

@Suite struct TextToolCallTests {
    @Test func xmlFunctionFormat() throws {
        let text = """
            Let me look.
            <tool_call>
            <function=read_file>
            <parameter=path>
            src/a.swift
            </parameter>
            <parameter=limit>40</parameter>
            </function>
            </tool_call>
            """
        let extraction = TextToolCalls.extract(from: text)
        #expect(extraction.text == "Let me look.")
        let call = try #require(extraction.calls.first)
        #expect(call.name == "read_file")
        #expect(call.arguments["path"] == "src/a.swift")
        #expect(call.arguments["limit"] == 40)
    }

    @Test func xmlWithoutClosingToolCall() {
        let extraction = TextToolCalls.extract(from: "<function=ls><parameter=dir>.</parameter></function>")
        #expect(extraction.calls.map(\.name) == ["ls"])
        #expect(extraction.text.isEmpty)
    }

    @Test func jsonFormatWithStringArguments() throws {
        let text = #"ok <tool_call>{"name": "search", "arguments": "{\"q\": \"swift\"}"}</tool_call>"#
        let extraction = TextToolCalls.extract(from: text)
        let call = try #require(extraction.calls.first)
        #expect(call.name == "search")
        #expect(call.arguments["q"] == "swift")
        #expect(extraction.text == "ok")
    }

    @Test func plainTextIsUntouched() {
        let extraction = TextToolCalls.extract(from: "  just text  ")
        #expect(extraction.calls.isEmpty)
        #expect(extraction.text == "  just text  ")
    }

    @Test func parameterValues() {
        #expect(TextToolCalls.value("true") == .bool(true))
        #expect(TextToolCalls.value("{\"a\": 1}") == ["a": 1])
        #expect(TextToolCalls.value("\nline one\nline two\n") == "line one\nline two")
        #expect(TextToolCalls.value("[not json") == "[not json")
    }
}

@Suite struct RepetitionGuardTests {
    @Test func detectsLoops() {
        let unit = "The answer is to restart the server again. "
        #expect(RepetitionGuard.isLooping("Intro text. " + String(repeating: unit, count: 12)))
    }

    @Test func ignoresNormalTextAndWhitespace() {
        let prose = (0..<60).map { "Sentence number \($0) says something different." }.joined(separator: " ")
        #expect(!RepetitionGuard.isLooping(prose))
        #expect(!RepetitionGuard.isLooping(String(repeating: "-", count: 2000)))
        #expect(!RepetitionGuard.isLooping("short"))
    }
}

@Suite struct ChatTypesTests {
    @Test func stopReasons() {
        #expect(StopReason(apiValue: nil) == .endTurn)
        #expect(StopReason(apiValue: "stop") == .endTurn)
        #expect(StopReason(apiValue: "tool_calls") == .toolUse)
        #expect(StopReason(apiValue: "length") == .maxTokens)
        #expect(StopReason(apiValue: "content_filter") == .refusal(nil))
        #expect(StopReason(apiValue: "pause_turn") == .other("pause_turn"))
    }

    @Test func messageHelpers() {
        let image = ImageAttachment(name: "a.png", mediaType: "image/png", data: Data([1, 2, 3]))
        #expect(image.dataURL == "data:image/png;base64,AQID")
        #expect(ChatMessage.user("hi").images == nil)
        #expect(ChatMessage.user("hi", images: [image]).images?.count == 1)
        let call = ToolCall(id: "c1", name: "ls", arguments: [:])
        let result = ChatMessage.toolResult(for: call, output: "out", isError: true)
        #expect(result.role == .tool && result.toolCallID == "c1" && result.toolName == "ls" && result.isError)
    }

    @Test func errorMessages() {
        #expect(AIProviderError.missingAPIKey("Claude").errorDescription == "No API key configured for Claude.")
        #expect(AIProviderError.http(status: 402, body: "no credit left").errorDescription?.hasPrefix("Out of credit") == true)
        #expect(AIProviderError.http(status: 500, body: "boom").errorDescription == "HTTP 500: boom")
        #expect(AIProviderError.unavailable("off").errorDescription == "off")
    }
}

/// Collects the events a parser produced in a compact, comparable form.
private func summary(_ events: [ChatEvent]) -> [String] {
    events.map { event in
        switch event {
        case .textDelta(let text): "text:\(text)"
        case .toolCall(let call): "call:\(call.id):\(call.name):\(call.arguments.encodedString())"
        case .invalidToolCall(let id, let name, let raw): "invalid:\(id):\(name):\(raw)"
        case .usage(let usage): "usage:\(usage.inputTokens)/\(usage.outputTokens)"
        case .status(let text): "status:\(text)"
        case .completed(let reason, _): "done:\(reason)"
        }
    }
}

@Suite struct OpenAIStreamTests {
    @Test func textAndStreamedToolCalls() throws {
        var parser = OpenAIStreamParser()
        var events: [ChatEvent] = []
        for payload in [
            #"{"choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{\"pa"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
            "not json",
        ] {
            events += try parser.consume(payload)
        }
        events += parser.finish()
        #expect(summary(events) == ["text:Hi", "usage:10/5", #"call:c1:read:{"path":"a"}"#, "done:toolUse"])
    }

    @Test func objectArgumentsAndInvalidJSON() throws {
        var parser = OpenAIStreamParser()
        _ = try parser.consume(#"{"choices":[{"delta":{"tool_calls":[{"function":{"name":"a","arguments":{"x":1}}},{"index":1,"id":"c2","function":{"name":"b","arguments":"{oops"}}]}}]}"#)
        let events = summary(parser.finish())
        #expect(events[1].hasPrefix("call:"))
        #expect(events[1].hasSuffix(#":a:{"x":1}"#))
        #expect(events[2] == "invalid:c2:b:{oops")
    }

    @Test func errorsThrowAndPlainStopsEnd() throws {
        var parser = OpenAIStreamParser()
        #expect(throws: AIProviderError.self) { try parser.consume(#"{"error":{"message":"rate limited"}}"#) }
        var plain = OpenAIStreamParser()
        _ = try plain.consume(#"{"choices":[{"delta":{"content":""},"finish_reason":"length"}]}"#)
        #expect(summary(plain.finish()) == ["usage:0/0", "done:maxTokens"])
    }

    @Test func requestBody() throws {
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3:8b", apiKey: "k", fallbackModels: ["b"])
        let tool = ToolDefinition(name: "ls", description: "list", inputSchema: ["type": "object"])
        let request = provider.makeURLRequest(ChatRequest(system: "sys", messages: [.user("hi")], tools: [tool]))
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer k")
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["models"] == ["qwen3:8b", "b"])
        #expect(body["messages"]?.arrayValue?.first?["role"] == "system")
        #expect(body["tools"]?.arrayValue?.first?["function"]?["name"] == "ls")
        #expect(provider.contextTokens == 12_000)
        #expect(provider.displayName.contains("1 backups"))
        #expect(!provider.supportsImages)
        #expect(OpenAICompatibleProvider.isVisionModel("llava:13b"))
    }

    @Test func convertsTranscript() {
        let image = ImageAttachment(name: "a", mediaType: "image/png", data: Data([0]))
        let call = ToolCall(id: "c1", name: "ls", arguments: ["dir": "."])
        let messages = OpenAICompatibleProvider.convert([
            .user("look", images: [image]),
            ChatMessage(role: .assistant, text: "", toolCalls: [call]),
            .toolResult(for: call, output: "a b", isError: false),
        ])
        #expect(messages[0]["content"]?.arrayValue?.count == 2)
        #expect(messages[1]["content"] == .null)
        #expect(messages[1]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"] == #"{"dir":"."}"#)
        #expect(messages[2]["tool_call_id"] == "c1")
    }
}

@Suite struct AnthropicStreamTests {
    @Test func textThinkingAndToolUse() throws {
        var parser = AnthropicStreamParser(providerID: "anthropic:test")
        var events: [ChatEvent] = []
        for payload in [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"ls","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"dir\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\".\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
        ] {
            events += try parser.consume(payload)
        }
        let finished = parser.finish()
        #expect(summary(events + finished) == ["text:Hello", "usage:12/7", #"call:t1:ls:{"dir":"."}"#, "done:toolUse"])
        guard case .completed(_, let content?) = finished.last else { Issue.record("no provider content"); return }
        let blocks = try #require(content.blocks.arrayValue)
        #expect(blocks.count == 3)
        #expect(blocks[0]["thinking"] == "hmm")
        #expect(blocks[0]["signature"] == "sig")
        #expect(blocks[1]["text"] == "Hello")
        #expect(blocks[2]["input"] == ["dir": "."])
    }

    @Test func truncatedToolInputIsNeverExecuted() throws {
        var parser = AnthropicStreamParser(providerID: "p")
        for payload in [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"rm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t2","name":"ok"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ] {
            _ = try parser.consume(payload)
        }
        let events = summary(parser.finish())
        #expect(events.contains("invalid:t2:ok:{}"))
        #expect(events.contains(#"invalid:t1:rm:{"path":"/"#))
        #expect(events.last == "done:maxTokens")
        #expect(!events.contains { $0.hasPrefix("call:") })
    }

    @Test func refusalCarriesCategoryAndErrorsThrow() throws {
        var parser = AnthropicStreamParser(providerID: "p")
        _ = try parser.consume(#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}}}"#)
        guard case .completed(let reason, _) = parser.finish().last else { Issue.record("no completion"); return }
        #expect(reason == .refusal("cyber"))
        #expect(throws: AIProviderError.self) { try parser.consume(#"{"type":"error","error":{"message":"overloaded"}}"#) }
    }

    @Test func convertMergesToolResultsAndReplaysNativeBlocks() {
        let call = ToolCall(id: "t1", name: "ls", arguments: "not an object")
        let native = ProviderContent(providerID: "anthropic:m", blocks: [["type": "text", "text": "native"]])
        let messages = AnthropicProvider.convert([
            .user("hi"),
            ChatMessage(role: .assistant, text: "", toolCalls: [call]),
            .toolResult(for: call, output: "", isError: true),
            .toolResult(for: ToolCall(id: "t2", name: "x", arguments: [:]), output: "two", isError: false),
            ChatMessage(role: .assistant, text: "ignored", providerContent: native),
            ChatMessage(role: .assistant, text: ""),
        ], providerID: "anthropic:m")
        #expect(messages.count == 4)
        #expect(messages[1]["content"]?.arrayValue?.first?["input"] == [:])
        let results = messages[2]["content"]?.arrayValue
        #expect(results?.count == 2)
        #expect(results?.first?["content"] == "(empty)")
        #expect(results?.first?["is_error"] == true)
        // Consecutive assistant turns merge too; an empty turn becomes "(no output)".
        #expect(messages[3]["content"]?.arrayValue?.map { $0["text"] } == ["native", "(no output)"])
    }

    @Test func requestHeadersAndBody() throws {
        let provider = AnthropicProvider(apiKey: "key", model: "claude-test", effort: "low")
        let request = provider.makeURLRequest(ChatRequest(system: "s", messages: [.user("q")], tools: [
            ToolDefinition(name: "ls", description: "d", inputSchema: ["type": "object"]),
        ], maxTokens: 100))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "key")
        #expect(request.url?.path() == "/v1/messages")
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["max_tokens"] == 100)
        #expect(body["output_config"]?["effort"] == "low")
        #expect(body["tools"]?.arrayValue?.first?["input_schema"]?["type"] == "object")
        #expect(provider.supportsImages)
    }
}

@Suite struct ResponsesStreamTests {
    @Test func functionCallsFromArgumentDeltas() throws {
        var parser = ResponsesStreamParser(providerID: "openai:gpt")
        var events: [ChatEvent] = []
        for payload in [
            #"{"type":"response.output_text.delta","delta":"Hi"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc1","delta":"{\"a\":"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc1","delta":"1}"}"#,
            #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc1","call_id":"call_1","name":"f"}}"#,
            #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc2","call_id":"call_2","name":"g","arguments":"{bad"}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":4}}}"#,
        ] {
            events += try parser.consume(payload)
        }
        #expect(summary(events + parser.finish()) == ["text:Hi", "usage:3/4", #"call:call_1:f:{"a":1}"#, "invalid:call_2:g:{bad", "done:toolUse"])
    }

    @Test func truncatedResponsesAndFailures() throws {
        var parser = ResponsesStreamParser(providerID: "p")
        _ = try parser.consume(#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c","name":"f","arguments":"{}"}}"#)
        _ = try parser.consume(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#)
        #expect(summary(parser.finish()) == ["usage:0/0", "invalid:c:f:{}", "done:maxTokens"])
        #expect(throws: AIProviderError.self) { try parser.consume(#"{"type":"response.failed","response":{"error":{"message":"x"}}}"#) }
        #expect(throws: AIProviderError.self) { try parser.consume(#"{"type":"error","message":"y"}"#) }
    }

    @Test func convertAndBody() throws {
        let provider = OpenAIResponsesProvider(apiKey: "k", model: "gpt-5", effort: "low")
        let call = ToolCall(id: "c1", name: "f", arguments: ["a": 1])
        let items = OpenAIResponsesProvider.convert([
            .user("hi", images: [ImageAttachment(name: "i", mediaType: "image/jpeg", data: Data([1]))]),
            ChatMessage(role: .assistant, text: "thinking", toolCalls: [call]),
            .toolResult(for: call, output: "", isError: false),
        ], providerID: provider.id)
        #expect(items.count == 4)
        #expect(items[0]["content"]?.arrayValue?.last?["type"] == "input_image")
        #expect(items[2]["type"] == "function_call")
        #expect(items[3]["output"] == "(empty)")
        let body = try JSONValue.parse(try #require(provider.makeURLRequest(ChatRequest(system: "s", messages: [.user("q")])).httpBody))
        #expect(body["reasoning"]?["effort"] == "low")
        #expect(body["store"] == false)
    }
}

@Suite struct ModelCatalogTests {
    static let gb: UInt64 = 1_073_741_824

    @Test func fitScalesWithBudget() throws {
        let small = try #require(ModelCatalog.model(id: "mlx-community/Qwen3-1.7B-4bit"))
        let big = try #require(ModelCatalog.model(id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"))
        #expect(ModelCatalog.fit(small, budgetBytes: 16 * Self.gb) == .great)
        #expect(ModelCatalog.fit(big, budgetBytes: 16 * Self.gb) == .tooLarge)
        #expect(ModelCatalog.fit(big, budgetBytes: 24 * Self.gb) == .tight)
        #expect(ModelFit.great < ModelFit.tooLarge)
        #expect(!ModelFit.tight.label.isEmpty)
    }

    @Test func recommendationsPickTheBestThatFits() throws {
        let picks = try #require(ModelCatalog.simplePicks(budgetBytes: 16 * Self.gb))
        #expect(ModelCatalog.fit(picks.best, budgetBytes: 16 * Self.gb) <= .good)
        if let lighter = picks.lighter { #expect(lighter.downloadGB < picks.best.downloadGB) }
        if let smarter = picks.smarter { #expect(smarter.quality > picks.best.quality) }
        #expect(ModelCatalog.recommended(budgetBytes: 1 * Self.gb) == nil)
        // Nothing fits comfortably: still offer the smallest model.
        #expect(ModelCatalog.simplePicks(budgetBytes: 1 * Self.gb)?.best.id == "mlx-community/Qwen3-1.7B-4bit")
        #expect(ModelCatalog.launcherDefault(budgetBytes: 8 * Self.gb).id == "mlx-community/Qwen3-1.7B-4bit")
        #expect(ModelCatalog.launcherDefault(budgetBytes: 48 * Self.gb).id == "mlx-community/Qwen3-4B-4bit")
    }

    @Test func starsAndDescriptions() {
        for model in ModelCatalog.all {
            #expect((1...5).contains(model.qualityStars))
            #expect((1...5).contains(model.speedStars))
            #expect(!model.plainDescription.isEmpty)
            #expect(model.requiredGB > model.downloadGB)
        }
        // Mixture-of-experts models count as faster than their download size suggests.
        let moe = ModelCatalog.model(id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")!
        #expect(moe.speedStars >= 3)
    }
}

@Suite struct ProviderSettingsTests {
    @Test func localFirstOrder() {
        var settings = ProviderSettings()
        settings.main = .mlx
        #expect(settings.activeOrder == [.mlx, .apple])
        settings.cloudEnabled = true
        #expect(settings.activeOrder == [.mlx, .apple, .openRouter, .openCode, .anthropic, .openAI])
        settings.auto = false
        settings.main = .anthropic
        #expect(settings.activeOrder == [.anthropic])
        settings.cloudEnabled = false
        // A cloud main is dropped when clouds are off: nothing leaves the Mac.
        #expect(settings.activeOrder.isEmpty)
    }

    @Test func tolerantDecodingAndPersistence() throws {
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: Data(#"{"main":"apple","cloudEnabled":"yes","unknown":1}"#.utf8))
        #expect(decoded.main == .apple)
        #expect(decoded.cloudEnabled == false)
        #expect(decoded.openAIBaseURL == ProviderSettings().openAIBaseURL)

        let suite = "Lizard.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ProviderSettings.hasSaved(in: defaults))
        var settings = ProviderSettings()
        settings.openAIModel = "llama3"
        settings.save(to: defaults)
        #expect(ProviderSettings.hasSaved(in: defaults))
        #expect(ProviderSettings.load(from: defaults).openAIModel == "llama3")
    }

    @Test func providersNeedKeys() {
        var settings = ProviderSettings()
        settings.main = .openAICompatible
        settings.auto = false
        #expect(settings.makeProviders(mlx: nil, key: { _ in nil }).first?.displayName == "Ollama (qwen3:8b)")
        settings.main = .openRouter
        settings.cloudEnabled = true
        #expect(settings.makeProviders(mlx: nil, key: { _ in nil }).isEmpty)
        let providers = settings.makeProviders(mlx: nil, key: { $0 == Keychain.openRouterAccount ? "sk" : nil })
        #expect(providers.first?.displayName.hasPrefix("OpenRouter") == true)
        #expect(ProviderKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.shortTitle.isEmpty })
        #expect(ProviderKind.openCode.isCloud && !ProviderKind.mlx.isCloud)
    }
}

@Suite struct ModelDirectoryTests {
    @Test func openRouterParsingAndRanking() {
        let json: [String: Any] = ["data": [
            ["id": "qwen/qwen3-coder:free", "name": "Qwen", "created": 200, "context_length": 1000, "supported_parameters": ["tools"],
             "pricing": ["prompt": "0", "completion": "0"]],
            ["id": "anthropic/claude-opus-5", "created": 300, "supported_parameters": ["tools"], "pricing": ["prompt": "0.000015", "completion": "0.000075"]],
            ["id": "some/model:batch", "supported_parameters": ["tools"]],
            ["id": "no/tools", "supported_parameters": ["temperature"]],
            ["id": "z-ai/glm-4:free", "created": 100, "context_length": 9000, "supported_parameters": ["tools"]],
        ]]
        let models = ModelDirectory.parseOpenRouter(json)
        #expect(models.map(\.id) == ["qwen/qwen3-coder:free", "z-ai/glm-4:free", "anthropic/claude-opus-5"])
        #expect(models[2].inputPrice == 15)
        #expect(models[0].isFree)
        #expect(ModelDirectory.defaultOpenRouterModel(from: models) == "anthropic/claude-opus-5")
        #expect(ModelDirectory.popularOpenRouterModels(from: models).map(\.id) == ["anthropic/claude-opus-5"])
        // Preferred families first: qwen3 before glm even with a smaller context.
        #expect(OpenRouterFree.rank(models) == ["qwen/qwen3-coder:free", "z-ai/glm-4:free"])
    }

    @Test func autoRouting() throws {
        let free = try #require(OpenRouterFree.routing(for: OpenRouterFree.autoModelID))
        #expect(([free.model] + free.fallbacks).last == OpenRouterFree.router)
        let mixed = try #require(OpenRouterFree.routing(for: OpenRouterFree.autoMixedID))
        #expect(mixed.fallbacks.last == OpenRouterFree.paidRouter)
        #expect(OpenRouterFree.routing(for: "anthropic/claude") == nil)
        #expect(OpenRouterFree.isAuto(OpenRouterFree.autoMixedID))
    }

    @Test func openAIAndAnthropicDefaults() {
        #expect(ModelDirectory.isOpenAIChatModel("gpt-5"))
        #expect(ModelDirectory.isOpenAIChatModel("o3"))
        #expect(!ModelDirectory.isOpenAIChatModel("gpt-4o-audio-preview"))
        #expect(!ModelDirectory.isOpenAIChatModel("text-embedding-3-large"))
        let date = Date(timeIntervalSince1970: 0)
        let openAI = [
            ModelDirectory.RemoteModel(id: "gpt-5-2025-08-07", name: "", created: date),
            ModelDirectory.RemoteModel(id: "gpt-5-mini", name: "", created: date),
            ModelDirectory.RemoteModel(id: "gpt-5", name: "", created: date),
        ]
        #expect(ModelDirectory.defaultOpenAIModel(from: openAI) == "gpt-5")
        let anthropic = [
            ModelDirectory.RemoteModel(id: "claude-sonnet-4", name: "", created: Date(timeIntervalSince1970: 50)),
            ModelDirectory.RemoteModel(id: "claude-opus-4", name: "", created: Date(timeIntervalSince1970: 10)),
        ]
        #expect(ModelDirectory.defaultAnthropicModel(from: anthropic) == "claude-opus-4")
        #expect(ModelDirectory.defaultAnthropicModel(from: anthropic + [.init(id: AnthropicProvider.defaultModel, name: "", created: nil)]) == AnthropicProvider.defaultModel)
        #expect(ModelDirectory.DirectoryError.http(401, "").errorDescription?.contains("rejected") == true)
    }
}

@Suite struct OAuthAndPromptTests {
    @Test func callbackParsing() {
        #expect(OpenRouterAuth.code(fromRequest: "GET /callback?code=abc123 HTTP/1.1\r\nHost: x\r\n") == .some("abc123"))
        #expect(OpenRouterAuth.code(fromRequest: "GET /callback?error=denied HTTP/1.1\r\n") == .some(nil))
        #expect(OpenRouterAuth.code(fromRequest: "GET /favicon.ico HTTP/1.1\r\n") == nil)
        #expect(OpenRouterAuth.code(fromRequest: "") == nil)
    }

    @Test func pkceVerifierIsURLSafe() {
        let verifier = OpenRouterAuth.randomVerifier()
        #expect(verifier.count == 64)
        #expect(verifier.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
        #expect(Data([0xFB, 0xFF]).base64URLEncoded() == "-_8")
    }

    @Test func appleProviderFoldsHistory() {
        #expect(AppleFMProvider.prompt(from: []) == "")
        #expect(AppleFMProvider.prompt(from: [.user("only")]) == "only")
        let prompt = AppleFMProvider.prompt(from: [.user("a"), ChatMessage(role: .assistant, text: "b"), .user("c")])
        #expect(prompt == "Conversation so far:\nUser: a\nAssistant: b\n\nUser: c")
    }

    @Test func openCodeFallsBackToDefaultModel() {
        #expect(OpenCodeZen.provider(apiKey: "k", model: "").model == OpenCodeZen.fallbackModel)
        #expect(OpenCodeZen.provider(apiKey: "k", model: "glm").model == "glm")
    }
}

/// A provider that replays fixed events (or fails), for job tests.
private struct ScriptedProvider: AIProvider {
    let id: String
    var displayName: String { id }
    let deltas: [String]
    var failure: Error?

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(.textDelta(delta)) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }
}

@Suite struct AIJobTests {
    @Test func jobsFallBackToTheNextProvider() async throws {
        let broken = ScriptedProvider(id: "broken", deltas: ["par"], failure: AIProviderError.unavailable("down"))
        let empty = ScriptedProvider(id: "empty", deltas: ["   "])
        let good = ScriptedProvider(id: "good", deltas: ["<think>plan</think>", " - done"])
        let result = try #require(await AIJobRunner.run(.summarize(text: "x"), providers: [broken, empty, good]))
        #expect(result.provider == "good")
        #expect(result.text == "- done")
        #expect(await AIJobRunner.run(.answer(question: "q"), providers: [empty]) == nil)
    }

    @Test func cleaningThinkBlocks() {
        #expect(AIJobRunner.cleaned("<think>a</think>\nAnswer") == "Answer")
        #expect(AIJobRunner.cleaned("Answer <think>unfinished") == "Answer")
        #expect(AIJobRunner.cleaned("  plain  ") == "plain")
    }

    @Test func promptsAndLimits() {
        let jobs: [AIJob] = [
            .summarize(text: String(repeating: "a", count: 20_000)), .summarizeWorkLog(entries: "e", period: "May"),
            .performanceReview(entries: "e", period: "H1", focus: "mentoring"), .explain(text: "x"),
            .rewrite(text: "t", style: "formal"), .answer(question: "q"),
        ]
        for job in jobs {
            #expect(!job.title.isEmpty)
            #expect(job.timeout >= 45)
            #expect(job.prompt.maxTokens > 0)
        }
        #expect(jobs[0].prompt.user.count == 12_000)
        #expect(jobs[2].prompt.system.contains("mentoring"))
        #expect(jobs[4].title == "Rewritten (formal)")
    }
}

@Suite struct ChatOrderTests {
    @Test func appleFirstWithoutCloud() {
        var settings = ProviderSettings()
        settings.cloudEnabled = false
        #expect(settings.chatOrder == [.apple, .mlx])
    }

    @Test func connectedCloudFirst() {
        var settings = ProviderSettings()
        settings.cloudEnabled = true
        settings.main = .anthropic
        #expect(settings.chatOrder.first == .anthropic)
        #expect(settings.chatOrder.suffix(2) == [.apple, .mlx])
        // A cloud without a key is skipped, leaving Apple Intelligence to answer.
        let providers = settings.makeProviders(mlx: nil, key: { _ in nil }, order: settings.chatOrder)
        #expect(providers.allSatisfy { $0.id == "apple" })
    }
}
