import Testing
@testable import AIEngine

@Suite struct AIVendorTests {
    private struct Fake: AIProvider {
        let id: String
        var displayName: String { id }
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> { AsyncThrowingStream { $0.finish() } }
    }

    @Test(arguments: [
        ("Anthropic_Claude_Sonnet", AIVendor.anthropic), ("anthropic-claude-haiku", .anthropic),
        ("OpenAI_GPT4o", .openAI), ("openai-gpt-4o-mini", .openAI), ("o3-mini", .openAI),
        ("Google_Gemini_Pro", .google),
    ])
    func recognisesRaycastModelNames(name: String, vendor: AIVendor) {
        #expect(AIVendor(modelName: name) == vendor)
    }

    @Test func unknownOrMissingModelHasNoVendor() {
        #expect(AIVendor(modelName: nil) == nil)
        #expect(AIVendor(modelName: "") == nil)
        #expect(AIVendor(modelName: "Llama3_70B") == nil)
    }

    @Test func ownAccountGoesFirst() {
        let providers: [any AIProvider] = [Fake(id: "apple"), Fake(id: "openai:gpt-5"), Fake(id: "anthropic:claude-sonnet-4-5")]
        let ordered = AIVendor.order(providers, for: "Anthropic_Claude_Sonnet", cloudAllowed: true) { _ in nil }
        #expect(ordered.map(\.id) == ["anthropic:claude-sonnet-4-5", "apple", "openai:gpt-5"])
    }

    @Test func fallsBackToOpenRouterForTheVendor() {
        let providers: [any AIProvider] = [Fake(id: "apple")]
        let ordered = AIVendor.order(providers, for: "OpenAI_GPT4o", cloudAllowed: true) { Fake(id: "openai-compatible:https://openrouter.ai/api/v1:\($0)") }
        #expect(ordered.first?.id.hasSuffix("openai/gpt-5") == true)
        #expect(ordered.count == 2)
    }

    @Test func cloudOffKeepsTheUsualOrder() {
        let providers: [any AIProvider] = [Fake(id: "apple"), Fake(id: "anthropic:claude")]
        let ordered = AIVendor.order(providers, for: "Anthropic_Claude_Sonnet", cloudAllowed: false) { _ in Fake(id: "x") }
        #expect(ordered.map(\.id) == ["apple", "anthropic:claude"])
    }
}
