import AIEngine
import AIEngineMLX
import Foundation
import LizardCore
import Observation

/// Everything AI for the app: which providers answer (Apple → MLX → opt-in clouds), the local
/// model download, and one-shot jobs. Ported from Cocoon's AppModel/SetupModel AI parts.
@Observable
@MainActor
final class AIService {
    var settings: ProviderSettings {
        didSet { settings.save() }
    }
    private(set) var download = DownloadState.idle
    let resources = ResourceMonitor()

    enum DownloadState: Equatable {
        case idle
        case running(fraction: Double, text: String)
        case loading
        case failed(String)
        case done
    }

    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init() {
        settings = ProviderSettings.load()
        MLXErrorTrap.install()
        Task.detached { Keychain.prefetch() }
    }

    var appleAvailable: Bool { AppleIntelligence.isAvailable }
    var localModel: LocalModel? { ModelCatalog.model(id: settings.mlxModelID) }
    /// Checking means listing the model folder, and chat views ask on every streamed token, so
    /// the answer is cached per model and refreshed when a download finishes.
    @ObservationIgnored private var downloadedModels: [String: Bool] = [:]
    var isLocalModelDownloaded: Bool {
        let id = settings.mlxModelID
        if let known = downloadedModels[id] { return known }
        let downloaded = ModelStore.isDownloaded(id)
        downloadedModels[id] = downloaded
        return downloaded
    }

    /// Providers in the order they should be tried. MLX is only offered once downloaded, so a
    /// chat never silently starts a multi-GB download.
    func providers() -> [any AIProvider] {
        let mlx: (any AIProvider)? = isLocalModelDownloaded ? MLXProvider(modelID: settings.mlxModelID) : nil
        return settings.makeProviders(mlx: mlx, key: { Keychain.cachedValue($0) ?? nil })
    }

    var hasAnyProvider: Bool { !providers().isEmpty }

    /// Short label of what will answer, for the chat header.
    var activeProviderName: String { providers().first?.displayName ?? "No AI set up" }

    func run(_ job: AIJob, onPartial: (@Sendable (String) -> Void)? = nil) async -> (text: String, provider: String)? {
        await AIJobRunner.run(job, providers: providers(), onPartial: onPartial)
    }

    /// AI for extensions (`AI.ask` / `useAI`): the person's own setup, with their matching cloud
    /// account first when the extension names a model (Claude, GPT, Gemini) and cloud AI is on.
    func ask(_ prompt: String, model: String?, onPartial: (@Sendable (String) -> Void)? = nil) async -> (text: String, provider: String)? {
        let ordered = AIVendor.order(providers(), for: model, cloudAllowed: settings.cloudEnabled) { openRouterModel in
            guard let key = Keychain.cachedValue(Keychain.openRouterAccount) ?? nil else { return nil }
            return OpenAICompatibleProvider(baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: openRouterModel, apiKey: key, label: "OpenRouter")
        }
        return await AIJobRunner.run(.answer(question: prompt), providers: ordered, onPartial: onPartial)
    }

    func prewarm() { AppleIntelligence.prewarm() }

    // MARK: Model download (from Cocoon's SetupModel.downloadModel: disk check, 90 s stall watchdog, 3 attempts)

    func downloadLocalModel() {
        guard downloadTask == nil else { return }
        let modelID = settings.mlxModelID
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                try await performDownload(modelID)
                downloadedModels.removeAll()
                download = .done
            } catch is CancellationError {
                download = .idle
            } catch {
                download = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    private func performDownload(_ modelID: String) async throws {
        if let model = ModelCatalog.model(id: modelID), !ModelStore.isDownloaded(modelID) {
            let needed = Int64(model.downloadGB * 1_000_000_000)
            guard DiskUsage.canFit(needed, reserve: 5 * 1_073_741_824) else {
                throw AIProviderError.unavailable("Not enough free disk space for this model (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) plus 5 GB spare).")
            }
        }
        download = .running(fraction: 0, text: "Connecting to Hugging Face…")
        let meter = RateMeter()
        for attempt in 1...3 {
            let last = LastProgress()
            let job = Task {
                _ = try await MLXModelHost.shared.container(for: modelID) { progress in
                    last.touch(progress.completedBytes)
                    if progress.fraction >= 1 { last.finishedBytes() }
                    Task { @MainActor in
                        self.download = progress.fraction >= 1
                            ? .loading
                            : .running(fraction: progress.fraction, text: meter.describe(completed: progress.completedBytes, total: progress.totalBytes))
                    }
                }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if last.silentFor > 90, !last.loadingIntoMemory {
                        job.cancel()
                        return
                    }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                watchdog.cancel()
                return
            } catch {
                watchdog.cancel()
                if Task.isCancelled { throw CancellationError() }
                let stalled = job.isCancelled
                guard stalled, attempt < 3 else {
                    if stalled { throw AIProviderError.unavailable("The download stopped making progress. Check your connection and try again. It resumes where it left off.") }
                    throw error
                }
                download = .running(fraction: 0, text: "Connection stalled, retrying (\(attempt + 1) of 3)…")
            }
        }
    }

    func prepareForTermination() async {
        downloadTask?.cancel()
        await MLXModelHost.shared.waitUntilIdle()
    }
}

/// "1.2 GB of 4.6 GB · 18 MB/s · about 3 min left" (from Cocoon's SetupModel).
final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(date: Date, bytes: Int64)] = []

    func describe(completed: Int64, total: Int64) -> String {
        lock.withLock {
            let now = Date()
            samples.append((now, completed))
            samples.removeAll { now.timeIntervalSince($0.date) > 8 }
            let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            var parts = [total > 0 ? "\(done) of \(all)" : done]
            if let first = samples.first, now.timeIntervalSince(first.date) > 1 {
                let rate = Double(completed - first.bytes) / now.timeIntervalSince(first.date)
                if rate > 0 {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
                    if total > completed {
                        let remaining = Double(total - completed) / rate
                        let formatter = DateComponentsFormatter()
                        formatter.unitsStyle = .abbreviated
                        formatter.allowedUnits = remaining > 3600 ? [.hour, .minute] : remaining > 60 ? [.minute] : [.second]
                        parts.append("about \(formatter.string(from: remaining) ?? "") left")
                    }
                }
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// When the download last made progress (written from the download callback).
private final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date.now
    private var bytes: Int64 = -1
    private var finished = false

    func touch(_ completed: Int64) {
        lock.withLock {
            if completed != bytes {
                bytes = completed
                date = .now
            }
        }
    }

    var silentFor: TimeInterval { lock.withLock { Date.now.timeIntervalSince(date) } }
    var loadingIntoMemory: Bool { lock.withLock { finished } }
    func finishedBytes() { lock.withLock { finished = true } }
}
