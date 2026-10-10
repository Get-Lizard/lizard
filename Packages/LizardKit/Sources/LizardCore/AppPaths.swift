import Foundation

/// On-disk locations used by Lizard.
public enum AppPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appending(path: "Lizard", directoryHint: .isDirectory))
    }

    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appending(path: "Lizard", directoryHint: .isDirectory))
    }

    public static var projects: URL { ensure(applicationSupport.appending(path: "Projects", directoryHint: .isDirectory)) }
    public static var diagnostics: URL { ensure(applicationSupport.appending(path: "Diagnostics", directoryHint: .isDirectory)) }
    public static var models: URL { ensure(applicationSupport.appending(path: "Models", directoryHint: .isDirectory)) }
    public static var simulatorSet: URL { ensure(applicationSupport.appending(path: "Simulators", directoryHint: .isDirectory)) }
    public static var scaffoldCache: URL { ensure(caches.appending(path: "Scaffolds", directoryHint: .isDirectory)) }
    public static var packageCache: URL { ensure(caches.appending(path: "PackageCaches", directoryHint: .isDirectory)) }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One line of output from a build, runtime or service.
public struct LogLine: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let date: Date
    public let source: String
    public let text: String

    public init(source: String, text: String, date: Date = .now) {
        self.source = source
        self.text = text
        self.date = date
    }
}

/// Fixed-size, thread-safe ring of recent log lines (feeds the agent's `get_logs` tool).
public final class LogRing: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private let capacity: Int

    public init(capacity: Int = 3000) {
        self.capacity = capacity
    }

    public func append(_ line: LogLine) {
        lock.withLock {
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func recent(_ count: Int) -> [LogLine] {
        lock.withLock { Array(lines.suffix(count)) }
    }
}

/// Finds free TCP ports on the loopback interface.
public enum PortFinder {
    /// Returns `preferred` if it is free on 127.0.0.1, otherwise an OS-assigned free port.
    public static func freePort(preferring preferred: Int) -> Int {
        if isFree(preferred) { return preferred }
        return bindEphemeral() ?? preferred + 10_000
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    static func bindEphemeral() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard bound else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        return named ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}

/// Disk usage helpers.
public enum DiskUsage {
    /// Allocated size of everything under `url`.
    public static func bytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Free space on the startup volume (what new downloads can use).
    public static func freeBytes() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Whether a download of `bytes` leaves at least `reserve` free afterwards.
    public static func canFit(_ bytes: Int64, reserve: Int64 = 10 * 1_073_741_824) -> Bool {
        freeBytes() - bytes >= reserve
    }
}
