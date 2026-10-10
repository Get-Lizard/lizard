import Darwin
import Foundation
import LizardCore

public enum ProcessKillError: Error, LocalizedError, Equatable {
    case notPermitted(Int32), noSuchProcess(Int32), failed(Int32, Int32)
    public var errorDescription: String? {
        switch self {
        case .notPermitted(let pid): "Not allowed to stop process \(pid) (it belongs to another user or the system)."
        case .noSuchProcess(let pid): "Process \(pid) has already exited."
        case .failed(let pid, let code): "Couldn't stop process \(pid) (error \(code))."
        }
    }
}

public enum ProcessKiller {
    /// SIGTERM (polite) or SIGKILL (force).
    public static func kill(pid: Int32, force: Bool = false) throws {
        guard Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
            switch errno {
            case EPERM: throw ProcessKillError.notPermitted(pid)
            case ESRCH: throw ProcessKillError.noSuchProcess(pid)
            default: throw ProcessKillError.failed(pid, errno)
            }
        }
    }
}

public struct RunningProcessInfo: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    public let cpu: Double
    public let memoryBytes: Int64
    public let user: String
    /// Full executable path.
    public let command: String

    public var name: String { (command as NSString).lastPathComponent }
    /// The .app bundle this process runs from, if any.
    public var appBundle: String? {
        guard let range = command.range(of: ".app/") else { return nil }
        return String(command[..<range.lowerBound]) + ".app"
    }
    public var isApp: Bool { appBundle != nil }
}

/// A `ps` snapshot of every process.
public enum ProcessList {
    public static func snapshot() async throws -> [RunningProcessInfo] {
        let result = try await ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,user=,comm="], timeout: .seconds(10))
        return parse(result.output)
    }

    /// Parses `ps -axo pid=,ppid=,pcpu=,rss=,user=,comm=` (rss in KiB; comm may contain spaces).
    public static func parse(_ output: String) -> [RunningProcessInfo] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let cpu = Double(fields[2]), let rss = Int64(fields[3]) else { return nil }
            return RunningProcessInfo(pid: pid, ppid: ppid, cpu: cpu, memoryBytes: rss * 1024, user: String(fields[4]), command: String(fields[5]).trimmingCharacters(in: .whitespaces))
        }
    }
}

public struct ListeningProcess: Sendable, Hashable, Identifiable {
    public var id: String { "\(pid):\(port)" }
    public let pid: Int32
    public let command: String
    public let port: Int
    public let address: String
    public let user: String
}

/// Who's listening on which TCP port (`lsof`), and stopping them.
public enum PortKiller {
    public static func listeningProcesses() async throws -> [ListeningProcess] {
        let result = try await ProcessRunner.run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP", "-FpcLn"], timeout: .seconds(15))
        return parse(result.output)
    }

    /// Parses `lsof -F pcLn` field output: `p<pid>`, `c<command>`, `L<user>`, then `f…`/`n<address:port>` per socket.
    public static func parse(_ output: String) -> [ListeningProcess] {
        var results: [ListeningProcess] = []
        var seen = Set<String>()
        var pid: Int32?
        var command = ""
        var user = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""; user = ""
            case "c": command = value
            case "L": user = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(port)"
                if seen.insert(key).inserted {
                    results.append(ListeningProcess(pid: pid, command: command, port: port, address: address, user: user))
                }
            default: continue
            }
        }
        return results.sorted { $0.port < $1.port }
    }

    public static func kill(_ process: ListeningProcess, force: Bool = false) throws {
        try ProcessKiller.kill(pid: process.pid, force: force)
    }
}
