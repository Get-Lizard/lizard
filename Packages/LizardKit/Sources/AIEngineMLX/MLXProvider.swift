import AIEngine
import Foundation
import LizardCore
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// MLX's default error handler calls `fatalError`, so any GPU/runtime error (for example
/// during app shutdown mid-generation) would crash the whole app. This trap records the
/// error instead; the provider then reports it as a normal, recoverable failure.
public enum MLXErrorTrap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastError: String?
    nonisolated(unsafe) private static var installed = false

    public static func install() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            setErrorHandler({ message, _ in
                let text = message.map { String(cString: $0) } ?? "Unknown MLX error"
                MLXErrorTrap.record(text)
            })
        }
    }

    static func record(_ message: String) {
        lock.withLock { lastError = message }
    }

    /// Returns and clears the last recorded error.
    static func take() -> String? {
        lock.withLock {
            defer { lastError = nil }
            return lastError
        }
    }
}

/// Byte-level progress of a model download.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var fraction: Double
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(fraction: Double, completedBytes: Int64, totalBytes: Int64) {
        self.fraction = fraction
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Keeps the KV cache of the last prompt so the next request only processes what changed.
/// Agent prompts share a long, stable beginning (system prompt, tools, project memory); without
/// this every tool call re-read ~5k tokens (most of the 21 minutes of the first CV eval).
final class PromptCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var cache: [KVCache]?
    private var inUse = false
    /// Below this, reusing isn't worth the bookkeeping.
    static let minimumReuse = 256

    /// A cache to generate with and how many leading prompt tokens it already holds.
    func checkout(prompt: [Int], newCache: () -> [KVCache]) -> (cache: [KVCache], reused: Int, owned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !inUse else { return (newCache(), 0, false) }  // parallel request: don't share
        inUse = true
        guard let cache, cache.allSatisfy(\.isTrimmable) else {
            let fresh = newCache()
            self.cache = fresh
            return (fresh, 0, true)
        }
        var common = 0
        let limit = min(tokens.count, prompt.count - 1)  // always process at least one token
        while common < limit, tokens[common] == prompt[common] { common += 1 }
        guard common >= Self.minimumReuse else {
            let fresh = newCache()
            self.cache = fresh
            return (fresh, 0, true)
        }
        for layer in cache { _ = layer.trim(layer.offset - common) }
        return (cache, common, true)
    }

    /// After generating: keep exactly the prompt in the cache for the next request.
    func checkin(prompt: [Int], owned: Bool, succeeded: Bool) {
        guard owned else { return }
        lock.lock()
        defer { lock.unlock() }
        inUse = false
        guard succeeded, let cache else {
            self.cache = nil
            tokens = []
            return
        }
        for layer in cache { _ = layer.trim(max(0, layer.offset - prompt.count)) }
        tokens = prompt
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
        tokens = []
        snapshot = nil
        snapshotTokens = []
    }

    // MARK: Hybrid models (Qwen3.5: recurrent layers can't be trimmed back to a shared prefix)

    /// A copy of the cache taken right before the part of the prompt that changes each step (the
    /// agent's status note). The next step starts from a copy of it and processes only what's new.
    /// Without it a hybrid model re-read the whole prompt (6–14k tokens, ~17 s) on every step.
    private var snapshot: [KVCache]?
    private var snapshotTokens: [Int] = []

    /// A cache for a model whose layers can't be trimmed: a copy of the snapshot when the prompt
    /// starts with its tokens (reused = how many), else a fresh one.
    func checkoutSnapshot(prompt: [Int], newCache: () -> [KVCache]) -> (cache: [KVCache], reused: Int, owned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !inUse else { return (newCache(), 0, false) }
        inUse = true
        if let snapshot, snapshotTokens.count >= Self.minimumReuse, snapshotTokens.count < prompt.count,
            prompt.starts(with: snapshotTokens)
        {
            return (snapshot.map { $0.copy() }, snapshotTokens.count, true)
        }
        return (newCache(), 0, true)
    }

    func saveSnapshot(tokens: [Int], cache: [KVCache]) {
        lock.lock()
        defer { lock.unlock() }
        snapshot = cache.map { $0.copy() }
        snapshotTokens = tokens
    }

    func releaseSnapshotCheckout(owned: Bool) {
        guard owned else { return }
        lock.lock()
        defer { lock.unlock() }
        inUse = false
    }
}

/// Owns the loaded local model. Applies this Mac's resource policy (GPU memory and cache caps),
/// keeps only one model resident, and unloads it after the policy's idle time.
public actor MLXModelHost {
    public static let shared = MLXModelHost()

    private var containers: [String: ModelContainer] = [:]
    private var loading: [String: Task<ModelContainer, Error>] = [:]
    private var lastUsed = Date()
    private var idleTask: Task<Void, Never>?
    private var activeGenerations = 0
    private var promptCaches: [String: PromptCacheBox] = [:]

    func promptCache(for modelID: String) -> PromptCacheBox {
        if let box = promptCaches[modelID] { return box }
        let box = PromptCacheBox()
        promptCaches[modelID] = box
        return box
    }

    init() {
        MLXErrorTrap.install()
    }

    /// Applies memory/cache caps from the current resource policy (call after changing mode).
    public func applyPolicy(_ policy: ResourcePolicy = .current) {
        GPU.set(memoryLimit: policy.mlxMemoryLimitBytes, relaxed: true)
        GPU.set(cacheLimit: policy.mlxCacheLimitBytes)
        scheduleIdleUnload(policy.modelIdleUnload)
    }

    /// Loads (downloading on first use) a model. The Hugging Face client hands over a single
    /// `Progress` that it mutates in place, so it is polled to report live bytes.
    public func container(
        for modelID: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> ModelContainer {
        lastUsed = Date()
        if let container = containers[modelID] { return container }
        applyPolicy()
        // Only one model resident at a time.
        if !containers.isEmpty {
            containers.removeAll()
            GPU.clearCache()
        }
        let box = ProgressBox()
        let meter = DiskDownloadMeter(modelID: modelID)
        let poller = Task {
            if !ModelStore.isDownloaded(modelID) { await meter.loadExpectedTotal() }
            var last: ModelDownloadProgress?
            var best: Double = 0
            while !Task.isCancelled {
                // Prefer the downloader's own progress; fall back to measuring the disk.
                let reported = box.snapshot()
                let candidate = (reported?.fraction ?? 0) > 0.001 ? reported : meter.snapshot()
                if let snapshot = candidate, snapshot != last, snapshot.fraction >= best {
                    best = snapshot.fraction
                    last = snapshot
                    progress(snapshot)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }
        if let task = loading[modelID] { return try await task.value }
        let task = Task<ModelContainer, Error> {
            var configuration = LLMRegistry.shared.configuration(id: modelID)
            // Qwen3-Coder shares `qwen3_moe` with plain Qwen3 (JSON tool calls) but emits the XML
            // function format, so the parser must be set explicitly.
            if configuration.toolCallFormat == nil, modelID.lowercased().contains("qwen3-coder") {
                configuration.toolCallFormat = .xmlFunction
            }
            return try await #huggingFaceLoadModelContainer(configuration: configuration) { value in
                box.set(value)
            }
        }
        loading[modelID] = task
        defer { loading[modelID] = nil }
        let container = try await task.value
        containers[modelID] = container
        lastUsed = Date()
        if let final = box.snapshot() {
            progress(ModelDownloadProgress(fraction: 1, completedBytes: final.totalBytes, totalBytes: final.totalBytes))
        }
        return container
    }

    func beginGeneration() {
        activeGenerations += 1
        lastUsed = Date()
    }

    // One generation at a time: MLX's compile cache and scheduler aren't safe for overlapping
    // generations (a SIGSEGV in CompilerCache::find was recorded). Others wait their turn (FIFO).
    private var slotTaken = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireGenerationSlot() async {
        guard slotTaken else {
            slotTaken = true
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    func releaseGenerationSlot() {
        if slotWaiters.isEmpty { slotTaken = false } else { slotWaiters.removeFirst().resume() }
    }

    /// Waits (up to `timeout`) until no generation is running and the GPU work is done — before
    /// quitting, so Metal completion handlers don't race C++ teardown (a recorded SIGABRT).
    public func waitUntilIdle(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while (activeGenerations > 0 || slotTaken), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        Stream.gpu.synchronize()
    }

    func endGeneration() {
        activeGenerations = max(0, activeGenerations - 1)
        lastUsed = Date()
        // Return freed buffers to the system instead of hoarding them.
        if ResourcePolicy.current.mode == .efficient { GPU.clearCache() }
    }

    private func scheduleIdleUnload(_ idle: Duration?) {
        idleTask?.cancel()
        guard let idle else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.unloadIfIdle(after: idle)
            }
        }
    }

    private func unloadIfIdle(after idle: Duration) {
        guard !containers.isEmpty, activeGenerations == 0, loading.isEmpty else { return }
        let seconds = Double(idle.components.seconds)
        if Date().timeIntervalSince(lastUsed) >= seconds {
            unloadAll()
        }
    }

    /// Frees all model memory (also used on memory pressure and before quitting).
    public func unloadAll() {
        guard activeGenerations == 0 else {
            GPU.clearCache()
            return
        }
        containers.removeAll()
        promptCaches.values.forEach { $0.reset() }
        promptCaches.removeAll()
        GPU.clearCache()
    }

    /// Drops cached GPU buffers without unloading the model.
    public func trimCache() {
        GPU.clearCache()
    }

    public func isLoaded(_ modelID: String) -> Bool { containers[modelID] != nil }

    public struct Usage: Sendable {
        public let loadedModel: String?
        public let activeBytes: Int
        public let cacheBytes: Int
        public let isGenerating: Bool
    }

    public func usage() -> Usage {
        Usage(loadedModel: containers.keys.first, activeBytes: GPU.activeMemory, cacheBytes: GPU.cacheMemory, isGenerating: activeGenerations > 0)
    }
}

/// Holds the latest `Progress` reported by the downloader (NSProgress is thread-safe to read).
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?

    func set(_ progress: Progress) {
        lock.withLock { self.progress = progress }
    }

    func snapshot() -> ModelDownloadProgress? {
        guard let progress = lock.withLock({ self.progress }) else { return nil }
        let fraction = min(max(progress.fractionCompleted, 0), 1)
        // The snapshot progress is weighted by file size, so its unit count is total bytes.
        let total = progress.totalUnitCount
        return ModelDownloadProgress(fraction: fraction, completedBytes: Int64(Double(total) * fraction), totalBytes: total)
    }
}

/// Local inference on the Metal GPU through mlx-swift-lm.
public struct MLXProvider: AIProvider {
    public let modelID: String

    public var id: String { "mlx:\(modelID)" }
    /// Prompt budget by this Mac's memory: the KV cache grows with every token, and both speed
    /// and small-model accuracy drop with long prompts.
    public var contextTokens: Int {
        let memory = HardwareProfile.current.memoryGB
        return memory <= 16 ? 8_000 : memory <= 24 ? 14_000 : memory <= 48 ? 20_000 : 28_000
    }

    public var displayName: String { "Local MLX (\(modelID.split(separator: "/").last.map(String.init) ?? modelID))" }

    public init(modelID: String) {
        self.modelID = modelID
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let modelID = modelID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let alreadyLoaded = await MLXModelHost.shared.isLoaded(modelID)
                    if !alreadyLoaded {
                        continuation.yield(.status("Loading \(modelID) (first use downloads it)…"))
                    }
                    let container = try await MLXModelHost.shared.container(for: modelID) { progress in
                        guard progress.fraction < 1 else { return }
                        let done = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
                        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                        continuation.yield(.status("Downloading \(modelID): \(done) of \(total) (\(Int(progress.fraction * 100))%)"))
                    }

                    let tools: [ToolSpec] = request.tools.map(Self.toolSpec)
                    // Qwen3-style templates read `enable_thinking`; others ignore unknown keys.
                    let input = UserInput(
                        chat: Self.chat(from: request), tools: tools.isEmpty ? nil : tools,
                        additionalContext: request.thinking.map { ["enable_thinking": $0] })
                    await MLXModelHost.shared.acquireGenerationSlot()
                    defer { Task { await MLXModelHost.shared.releaseGenerationSlot() } }
                    if Task.isCancelled { throw CancellationError() }
                    let prepared = try await container.prepare(input: input)
                    // Where the last message (the agent's status note — new every step) begins: tokenize
                    // once more with that message swapped; the two token lists part ways there.
                    var boundary = 0
                    if prepared.image == nil, request.messages.count >= 2, var variant = Optional(Self.chat(from: request)) {
                        variant[variant.count - 1] = .user("§")
                        let other = try await container.prepare(input: UserInput(
                            chat: variant, tools: tools.isEmpty ? nil : tools,
                            additionalContext: request.thinking.map { ["enable_thinking": $0] }))
                        let a = prepared.text.tokens.asArray(Int.self), b = other.text.tokens.asArray(Int.self)
                        while boundary < min(a.count, b.count), a[boundary] == b[boundary] { boundary += 1 }
                    }
                    // 4k output tokens is a whole component file; more is almost always a runaway.
                    let parameters = Self.sampling(for: modelID, maxTokens: min(request.maxTokens, 4096))
                    // Reuse the cached prefix of the previous prompt (text-only requests).
                    let box = await MLXModelHost.shared.promptCache(for: modelID)
                    let promptTokens: [Int] = prepared.image == nil ? prepared.text.tokens.asArray(Int.self) : []
                    let statusStart = boundary
                    let started = try await container.perform(nonSendable: prepared) { context, prepared in
                        guard !promptTokens.isEmpty else {
                            return (try MLXLMCommon.generate(input: prepared, parameters: parameters, context: context), false, 0)
                        }
                        let probe = context.model.newCache(parameters: parameters)
                        if !probe.allSatisfy(\.isTrimmable) {
                            // Hybrid model: restore the snapshot, process up to the status note, snapshot
                            // again there (for the next step), then the rest.
                            let checkout = box.checkoutSnapshot(prompt: promptTokens) { probe }
                            var position = checkout.reused
                            do {
                                if checkout.owned, statusStart - position >= 64, statusStart < promptTokens.count {
                                    try Self.prefill(context.model, tokens: Array(promptTokens[position..<statusStart]), cache: checkout.cache)
                                    box.saveSnapshot(tokens: Array(promptTokens[..<statusStart]), cache: checkout.cache)
                                    position = statusStart
                                }
                                let input = position == 0
                                    ? prepared
                                    : LMInput(text: .init(tokens: MLXArray(promptTokens[position...].map(Int32.init))))
                                let stream = try MLXLMCommon.generate(input: input, cache: checkout.cache, parameters: parameters, context: context)
                                box.releaseSnapshotCheckout(owned: checkout.owned)
                                return (stream, false, checkout.reused)
                            } catch {
                                box.releaseSnapshotCheckout(owned: checkout.owned)
                                throw error
                            }
                        }
                        let checkout = box.checkout(prompt: promptTokens) { probe }
                        let input = checkout.reused == 0
                            ? prepared
                            : LMInput(text: .init(tokens: MLXArray(promptTokens[checkout.reused...].map(Int32.init))))
                        do {
                            return (try MLXLMCommon.generate(input: input, cache: checkout.cache, parameters: parameters, context: context), checkout.owned, checkout.reused)
                        } catch {
                            box.checkin(prompt: promptTokens, owned: checkout.owned, succeeded: false)
                            throw error
                        }
                    }
                    let (stream, ownsCache, reused) = started
                    if reused > 0 { print("[mlx] reused \(reused) of \(promptTokens.count) prompt tokens") }
                    var finished = false
                    defer { if !promptTokens.isEmpty { box.checkin(prompt: promptTokens, owned: ownsCache, succeeded: finished) } }

                    var calls: [AIEngine.ToolCall] = []
                    var usage = TokenUsage()
                    _ = MLXErrorTrap.take()
                    await MLXModelHost.shared.beginGeneration()
                    defer { Task { await MLXModelHost.shared.endGeneration() } }
                    var recent = ""
                    var looping = false
                    // Tool calls stream nothing until they're complete: a heartbeat shows progress
                    // (and keeps the turn watchdog from mistaking a long answer for a hang).
                    let writingSince = Date.now
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(15))
                            if Task.isCancelled { break }
                            continuation.yield(.status("Still writing… \(Int(Date.now.timeIntervalSince(writingSince)))s"))
                        }
                    }
                    defer { heartbeat.cancel() }
                    for await generation in stream {
                        if Task.isCancelled { break }
                        switch generation {
                        case .chunk(let text):
                            // A model going in circles would otherwise run to the token limit
                            // (minutes on a local model). Stop and let the harness move on.
                            recent += text
                            if recent.count > 6000 { recent.removeFirst(recent.count - 6000) }
                            if RepetitionGuard.isLooping(recent) {
                                looping = true
                                break
                            }
                            continuation.yield(.textDelta(text))
                        case .toolCall(let call):
                            calls.append(Self.convert(call))
                        case .info(let info):
                            usage = TokenUsage(inputTokens: info.promptTokenCount, outputTokens: info.generationTokenCount)
                        }
                    }
                    if let failure = MLXErrorTrap.take() {
                        throw AIProviderError.unavailable("The local model failed: \(failure)")
                    }
                    if looping {
                        print("[mlx] stopped a repeating generation")
                        continuation.yield(.textDelta("\n(Stopped: the model was repeating itself.)"))
                    }
                    finished = !Task.isCancelled && !looping
                    continuation.yield(.usage(usage))
                    calls.forEach { continuation.yield(.toolCall($0)) }
                    continuation.yield(.completed(calls.isEmpty ? .endTurn : .toolUse, providerContent: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sampling tuned per family. Qwen3-Coder uses its published recommendation; a mild
    /// repetition penalty (over a long window) discourages "Let me create…" loops without
    /// harming code, where tokens legitimately repeat.
    /// Runs `tokens` through the model into `cache` without generating (all of them, not leaving the
    /// usual last chunk for the first generation step).
    static func prefill(_ model: any LanguageModel, tokens: [Int], cache: [KVCache]) throws {
        let input = LMInput(text: .init(tokens: MLXArray(tokens.map(Int32.init))))
        switch try model.prepare(input, cache: cache, windowSize: nil) {
        case .tokens(let rest):
            let output = model(rest[.newAxis], cache: cache, state: nil)
            eval(output.logits)
        case .logits(let result):
            eval(result.logits)
        }
        eval(cache)
    }

    static func sampling(for modelID: String, maxTokens: Int) -> GenerateParameters {
        let id = modelID.lowercased()
        if id.contains("qwen3-coder") {
            return GenerateParameters(maxTokens: maxTokens, temperature: 0.7, topP: 0.8, topK: 20, repetitionPenalty: 1.05, repetitionContextSize: 256)
        }
        // Qwen3 (thinking mode) per its model card; greedy/low temperatures cause repetition loops.
        if id.contains("qwen3") {
            return GenerateParameters(maxTokens: maxTokens, temperature: 0.6, topP: 0.95, topK: 20, repetitionPenalty: 1.05, repetitionContextSize: 256)
        }
        if id.contains("deepseek-r1") {
            return GenerateParameters(maxTokens: maxTokens, temperature: 0.6, topP: 0.95, repetitionPenalty: 1.05, repetitionContextSize: 256)
        }
        return GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9, topK: 40, repetitionPenalty: 1.05, repetitionContextSize: 256)
    }

    static func chat(from request: ChatRequest) -> [Chat.Message] {
        var chat: [Chat.Message] = [.system(request.system)]
        for message in request.messages {
            switch message.role {
            case .user:
                chat.append(.user(message.text))
            case .assistant:
                let calls = message.toolCalls.map { call in
                    MLXLMCommon.ToolCall(
                        function: .init(
                            name: call.name,
                            arguments: (call.arguments.objectValue ?? [:]).mapValues(\.sendableValue)),
                        id: call.id)
                }
                chat.append(.assistant(message.text, toolCalls: calls.isEmpty ? nil : calls))
            case .tool:
                chat.append(.tool(message.text, id: message.toolCallID))
            }
        }
        return chat
    }

    static func toolSpec(_ tool: ToolDefinition) -> ToolSpec {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.inputSchema.sendableValue,
            ] as [String: any Sendable],
        ]
    }

    static func convert(_ call: MLXLMCommon.ToolCall) -> AIEngine.ToolCall {
        let foundation = call.function.arguments.mapValues { $0.anyValue }
        let arguments: AIEngine.JSONValue =
            (try? JSONSerialization.data(withJSONObject: foundation)).flatMap { try? AIEngine.JSONValue.parse($0) } ?? [:]
        return AIEngine.ToolCall(
            id: call.id ?? "call_\(UUID().uuidString.prefix(8))", name: call.function.name, arguments: arguments)
    }
}
