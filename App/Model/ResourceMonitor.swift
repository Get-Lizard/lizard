import AIEngineMLX
import Foundation
import LizardCore
import Observation

/// Watches memory and reacts to pressure so Lizard never drags the Mac down:
/// warning → trim the AI model's GPU cache; critical → unload the model.
@Observable
@MainActor
final class ResourceMonitor {
    let profile = HardwareProfile.current
    private(set) var appFootprintBytes: UInt64 = 0
    private(set) var availableBytes: UInt64 = 0
    private(set) var modelBytes: Int = 0
    private(set) var loadedModel: String?
    private(set) var isGenerating = false
    private(set) var pressure: Pressure = .normal
    private(set) var lastAction: String?

    enum Pressure: String { case normal, warning, critical }

    var mode: PerformanceMode {
        didSet {
            PerformanceMode.current = mode
            Task { await MLXModelHost.shared.applyPolicy(ResourcePolicy(profile: profile, mode: mode)) }
        }
    }

    var policy: ResourcePolicy { ResourcePolicy(profile: profile, mode: mode) }

    /// Called on a macOS memory-pressure warning, so the app model can pause background apps.
    @ObservationIgnored var onPressure: (() -> Void)?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        mode = PerformanceMode.current
        Task { await MLXModelHost.shared.applyPolicy(ResourcePolicy(profile: profile, mode: mode)) }
        startPressureMonitoring()
        startPolling()
    }

    var usedFraction: Double {
        let total = Double(profile.memoryBytes)
        return total > 0 ? min(1, max(0, (total - Double(availableBytes)) / total)) : 0
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func sample() async {
        appFootprintBytes = SystemMetrics.processFootprintBytes()
        availableBytes = SystemMetrics.availableBytes()
        let usage = await MLXModelHost.shared.usage()
        modelBytes = usage.activeBytes + usage.cacheBytes
        loadedModel = usage.loadedModel
        isGenerating = usage.isGenerating
    }

    private func startPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.contains(.critical) {
                    self.pressure = .critical
                    self.onPressure?()
                    Task { await MLXModelHost.shared.unloadAll() }
                    self.lastAction = "Your Mac was low on memory, so the AI model was unloaded. It reloads automatically when needed."
                } else if event.contains(.warning) {
                    self.pressure = .warning
                    self.onPressure?()
                    Task { await MLXModelHost.shared.trimCache() }
                    self.lastAction = "Memory is getting tight; Lizard released cached AI memory."
                } else {
                    self.pressure = .normal
                }
            }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: Actions

    func note(_ text: String) {
        lastAction = text
    }

    func trimModelCache() async {
        await MLXModelHost.shared.trimCache()
        await sample()
    }

    func unloadModel() {
        Task {
            await MLXModelHost.shared.unloadAll()
            await sample()
            lastAction = "AI model unloaded. It reloads automatically the next time you chat."
        }
    }
}
