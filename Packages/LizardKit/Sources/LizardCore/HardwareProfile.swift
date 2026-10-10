import Darwin
import Foundation
import Metal

/// What this Mac can do. Everything resource-related (model fit, container/build/device
/// limits, preview frame rate) derives from this, so the app adapts to any machine.
public struct HardwareProfile: Sendable, Equatable {
    public let chip: String
    public let memoryBytes: UInt64
    public let performanceCores: Int
    public let efficiencyCores: Int
    /// Metal's recommended GPU working set (≈ how much unified memory models can use).
    public let gpuBudgetBytes: UInt64

    public static let current = HardwareProfile.detect()

    public var totalCores: Int { performanceCores + efficiencyCores }
    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }
    public var gpuBudgetGB: Double { Double(gpuBudgetBytes) / 1_073_741_824 }

    public var summary: String {
        String(format: "%@ · %.0f GB memory · %d cores (%dP + %dE)", chip, memoryGB, totalCores, performanceCores, efficiencyCores)
    }

    static func detect() -> HardwareProfile {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        let memory = ProcessInfo.processInfo.physicalMemory
        let performance = sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let gpu = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? UInt64(Double(memory) * 0.66)
        return HardwareProfile(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon", memoryBytes: memory,
            performanceCores: performance, efficiencyCores: efficiency, gpuBudgetBytes: gpu)
    }
}

/// How hard Lizard may push the machine.
public enum PerformanceMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case efficient, balanced, performance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .efficient: "Efficient"
        case .balanced: "Balanced"
        case .performance: "Performance"
        }
    }

    public var explanation: String {
        switch self {
        case .efficient: "Keeps your Mac responsive: smaller memory caps, AI model unloads quickly, builds use fewer cores."
        case .balanced: "Good speed while leaving room for your other apps."
        case .performance: "Uses most of this Mac for the fastest AI and builds. Other apps may slow down."
        }
    }

    private static let defaultsKey = "Lizard.PerformanceMode"

    /// The user's choice, or a sensible default for this machine.
    public static var current: PerformanceMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey), let mode = PerformanceMode(rawValue: raw) { return mode }
            return HardwareProfile.current.memoryGB <= 16 ? .efficient : .balanced
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Concrete limits for the current machine and mode.
public struct ResourcePolicy: Sendable {
    public let profile: HardwareProfile
    public let mode: PerformanceMode

    public static var current: ResourcePolicy { ResourcePolicy(profile: .current, mode: .current) }

    public init(profile: HardwareProfile, mode: PerformanceMode) {
        self.profile = profile
        self.mode = mode
    }

    private func pick<T>(_ efficient: T, _ balanced: T, _ performance: T) -> T {
        switch mode {
        case .efficient: efficient
        case .balanced: balanced
        case .performance: performance
        }
    }

    private static let mb = 1_048_576

    /// Hard cap for MLX GPU memory (model weights + KV cache).
    public var mlxMemoryLimitBytes: Int { Int(Double(profile.gpuBudgetBytes) * pick(0.6, 0.75, 0.9)) }
    /// MLX keeps freed buffers cached; unbounded, this is what makes a Mac sluggish.
    public var mlxCacheLimitBytes: Int { pick(256, 1024, 2048) * Self.mb }
    /// Unload the local model after this much idle time (nil = keep it loaded).
    public var modelIdleUnload: Duration? { pick(.seconds(120), .seconds(600), nil) }

    /// How many apps may keep running in the background (besides the one on screen) before
    /// Lizard pauses the least recently viewed. Apps the AI is working on are never paused.
    public var backgroundAppLimit: Int { pick(0, profile.memoryGB >= 32 ? 1 : 0, profile.memoryGB >= 32 ? 3 : 1) }
    /// A background app nobody has looked at for this long is paused.
    public var backgroundAppIdle: Duration { pick(.seconds(120), .seconds(600), .seconds(1800)) }

    /// CPUs and memory for an app container.
    public var containerCPUs: Int { max(1, pick(2, max(2, profile.performanceCores / 2), max(2, profile.performanceCores))) }
    public var containerMemoryMB: Int {
        let byRAM = profile.memoryGB >= 32 ? 4096 : profile.memoryGB >= 16 ? 2048 : 1024
        return pick(min(1024, byRAM), min(2048, byRAM), byRAM)
    }
    /// Memory for companion services (Postgres, …).
    public var serviceMemoryMB: Int { pick(512, 768, 1024) }

    /// Parallel compile jobs (xcodebuild -jobs, Gradle --max-workers).
    public var buildJobs: Int { max(1, pick(max(1, profile.performanceCores / 2), profile.performanceCores, profile.totalCores)) }
    public var gradleHeapMB: Int { pick(1536, 2048, profile.memoryGB >= 32 ? 4096 : 3072) }
    /// Keep the Gradle daemon warm for this long after a build (0 = no daemon).
    public var gradleDaemonIdleMinutes: Int { pick(0, 10, 60) }

    public var emulatorMemoryMB: Int { pick(1536, 2048, 3072) }
    public var emulatorCores: Int { pick(2, 2, 4) }

    /// Device preview refresh interval (screenshot-based previews).
    public var previewInterval: Duration { pick(.milliseconds(1500), .milliseconds(700), .milliseconds(350)) }
}

/// Live memory figures.
public enum SystemMetrics {
    /// Memory this process is charged for (what Activity Monitor shows as "Memory").
    public static func processFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Memory the system could hand out right now (free + inactive + purgeable + speculative).
    public static func availableBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return pages * UInt64(getpagesize())
    }
}
