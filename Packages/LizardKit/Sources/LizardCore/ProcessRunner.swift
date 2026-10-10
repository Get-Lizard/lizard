import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }

    /// The last `lines` lines of output, for compact error reporting.
    public func tail(_ lines: Int = 40) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

public enum ProcessError: Error, LocalizedError {
    case launchFailed(String, underlying: String)
    case timedOut(String)
    case failed(String, CommandResult)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let underlying): "Could not launch `\(cmd)`: \(underlying)"
        case .timedOut(let cmd): "`\(cmd)` timed out"
        case .failed(let cmd, let result): "`\(cmd)` exited with \(result.exitCode):\n\(result.tail(25))"
        }
    }
}

/// Thread-safe accumulator for process output that also splits it into lines.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        data.append(chunk)
        if onLine != nil {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish() -> String {
        lock.lock()
        let rest = pending
        pending.removeAll()
        let all = data
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        return String(decoding: all, as: UTF8.self)
    }
}

/// A long-running child process (dev server log follower, emulator, ...).
public final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}

public enum ProcessRunner {
    /// Runs `executable` (resolved against `ToolEnvironment.searchPath`) to completion.
    /// stdout and stderr are merged. Never throws for a non-zero exit; check `succeeded`.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        timeout: Duration? = nil,
        qos: QualityOfService = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = makeProcess(executable, arguments, cwd: cwd, environment: environment)
        // Heavy work (compilers, package managers) runs at lower priority so the Mac stays responsive.
        process.qualityOfService = qos
        let collector = OutputCollector(onLine: onLine)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        let commandLine = ([executable] + arguments).joined(separator: " ")
        let timedOut = TimeoutFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    let output = collector.finish()
                    if timedOut.value {
                        continuation.resume(throwing: ProcessError.timedOut(commandLine))
                    } else {
                        continuation.resume(returning: CommandResult(exitCode: finished.terminationStatus, output: output))
                    }
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessError.launchFailed(commandLine, underlying: error.localizedDescription))
                    return
                }
                if let timeout {
                    Task {
                        try? await Task.sleep(for: timeout)
                        if process.isRunning {
                            timedOut.value = true
                            process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs and throws `ProcessError.failed` on a non-zero exit.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        timeout: Duration? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments, cwd: cwd, environment: environment, timeout: timeout, onLine: onLine)
        guard result.succeeded else {
            throw ProcessError.failed(([executable] + arguments).joined(separator: " "), result)
        }
        return result
    }

    /// Starts a process that keeps running in the background, streaming its output lines.
    public static func launch(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        qos: QualityOfService = .utility,
        onLine: @escaping @Sendable (String) -> Void,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> RunningProcess {
        let process = makeProcess(executable, arguments, cwd: cwd, environment: environment)
        process.qualityOfService = qos
        let collector = OutputCollector(onLine: onLine)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            _ = collector.finish()
            onExit?(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(([executable] + arguments).joined(separator: " "), underlying: error.localizedDescription)
        }
        return RunningProcess(process: process)
    }

    private static func makeProcess(
        _ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]
    ) -> Process {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ToolEnvironment.shared.environment(merging: environment)
        return process
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
