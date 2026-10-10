import Foundation

/// The environment child processes run with. GUI apps inherit a minimal PATH, so we
/// rebuild one that finds Homebrew, nvm's node and Lizard's own GitHub CLI.
public final class ToolEnvironment: Sendable {
    public static let shared = ToolEnvironment()

    public let searchPath: [String]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.lizard/gh/bin"]
        if let nodeBin = Self.latestNVMNodeBin(home: home) { paths.append(nodeBin) }
        paths += ["\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        searchPath = (paths + inherited).filter { seen.insert($0).inserted }
    }

    public func environment(merging extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Absolute path of `tool` on the search path, if present.
    public func which(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchPath {
            let candidate = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func latestNVMNodeBin(home: String) -> String? {
        let versions = "\(home)/.nvm/versions/node"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versions) else { return nil }
        let sorted = entries.filter { $0.hasPrefix("v") }.sorted { lhs, rhs in
            lhs.compare(rhs, options: .numeric) == .orderedAscending
        }
        return sorted.last.map { "\(versions)/\($0)/bin" }
    }
}
