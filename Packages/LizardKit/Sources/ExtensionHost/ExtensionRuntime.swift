import Foundation
import LizardCore

/// What a running command sends to the app.
public enum HostEvent: Sendable {
    case render(tree: [ViewNode], depth: Int)
    /// Fire-and-forget notifications: toast.show, toast.hide, hud, closeMainWindow, popToRoot,
    /// updateCommandMetadata, openPreferences, clipboard.copied, clearSearchBar.
    case notify(method: String, params: HostJSON)
    /// A no-view command finished.
    case done
    case error(message: String, stack: String)
    case exited(Int32)
}

/// Native services an extension can call and wait for (paste, confirm, AI…). The app implements it.
public protocol HostServices: Sendable {
    func handle(method: String, params: HostJSON, context: ExtensionContext) async throws -> HostJSON
}

/// Which command is asking.
public struct ExtensionContext: Sendable, Hashable {
    public let extensionName: String
    public let commandName: String

    public init(extensionName: String, commandName: String) {
        self.extensionName = extensionName
        self.commandName = commandName
    }
}

public enum ExtensionHostError: Error, LocalizedError {
    case nodeMissing, shimMissing(String), launchFailed(String), buildFailed(String), notInstalled(String), download(String)

    public var errorDescription: String? {
        switch self {
        case .nodeMissing: "Extensions need Node.js. Install it with `brew install node` (or from nodejs.org) and try again."
        case .shimMissing(let path): "Lizard's extension runtime is missing (\(path)). Rebuild the app."
        case .launchFailed(let detail): "Couldn't start the extension: \(detail)"
        case .buildFailed(let detail): "Couldn't build the extension: \(detail)"
        case .notInstalled(let name): "The extension “\(name)” isn't installed."
        case .download(let detail): "Couldn't download the extension: \(detail)"
        }
    }
}

/// Where Node and the shim live.
public enum ExtensionHostPaths {
    /// The shim's `dist` folder: `LIZARD_SHIM_DIR`, the app bundle's `ExtensionShim`, or the
    /// source tree (development / CLI).
    public static var shimDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LIZARD_SHIM_DIR"] { return URL(filePath: override) }
        if let bundled = Bundle.main.resourceURL?.appending(path: "ExtensionShim"),
            FileManager.default.fileExists(atPath: bundled.appending(path: "host.js").path) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().appending(path: "js/dist")
    }

    /// A Node bundled in the app wins; otherwise the user's.
    public static var node: String? {
        if let bundled = Bundle.main.resourceURL?.appending(path: "node/bin/node"), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return ToolEnvironment.shared.which("node")
    }
}

/// One running command: a `node host.js` process speaking newline-delimited JSON on stdio.
/// (Not `ProcessRunner`: this needs a live stdin.)
public final class ExtensionRuntime: @unchecked Sendable {
    public let context: ExtensionContext
    public let events: AsyncStream<HostEvent>

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let continuation: AsyncStream<HostEvent>.Continuation
    private let lock = NSLock()
    /// Serialises writes to the host's stdin: callbacks from the main actor and service replies
    /// from background tasks would otherwise interleave lines longer than the pipe's atomic size.
    private let writeLock = NSLock()
    private var buffer = Data()
    private var launchMessage: [String: Any]?
    private let services: HostServices
    private var stderrTail = ""

    public init(context: ExtensionContext, services: HostServices) {
        self.context = context
        self.services = services
        (events, continuation) = AsyncStream<HostEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Starts Node and launches `bundle` once the host says it's ready.
    public func start(
        bundle: URL, command: ExtensionManifest.Command, extensionDirectory: URL, assetsPath: URL, supportPath: URL,
        author: String?, preferences: [String: HostJSON], launchType: String = "userInitiated",
        arguments: [String: String] = [:], launchContext: HostJSON? = nil, environment extra: [String: String] = [:]
    ) throws {
        guard let node = ExtensionHostPaths.node else { throw ExtensionHostError.nodeMissing }
        let host = ExtensionHostPaths.shimDirectory.appending(path: "host.js")
        guard FileManager.default.fileExists(atPath: host.path) else { throw ExtensionHostError.shimMissing(host.path) }
        try? FileManager.default.createDirectory(at: supportPath, withIntermediateDirectories: true)

        launchMessage = [
            "type": "launch", "bundle": bundle.path,
            "command": ["name": command.name, "mode": command.mode.rawValue],
            "extension": [
                "name": context.extensionName, "path": extensionDirectory.path, "assetsPath": assetsPath.path,
                "supportPath": supportPath.path, "author": author ?? "",
            ],
            "preferences": HostJSON.object(preferences).anyValue,
            "launchType": launchType, "arguments": arguments,
            "launchContext": launchContext?.anyValue ?? NSNull(),
        ]

        process.executableURL = URL(filePath: node)
        process.arguments = ["--enable-source-maps", host.path]
        process.environment = ToolEnvironment.shared.environment(merging: extra.merging(["NODE_NO_WARNINGS": "1"]) { $1 })
        process.currentDirectoryURL = extensionDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { self.stderrTail = String((self.stderrTail + text).suffix(4000)) }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            self.errors.fileHandleForReading.readabilityHandler = nil
            if finished.terminationStatus != 0 {
                let tail = self.lock.withLock { self.stderrTail }
                if !tail.isEmpty { self.continuation.yield(.error(message: "The extension stopped.", stack: tail)) }
            }
            self.continuation.yield(.exited(finished.terminationStatus))
            self.continuation.finish()
        }
        // Writing to a host that just exited would raise SIGPIPE and kill Lizard; make it an error instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw ExtensionHostError.launchFailed(error.localizedDescription)
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Calls a serialized function prop (`onAction`, `onChange`, `onSearchTextChange`…).
    public func invoke(_ callback: String, args: [HostJSON] = []) {
        send(["type": "event", "callback": callback, "args": args.map(\.anyValue)])
    }

    /// Pops the extension's navigation stack.
    public func pop() {
        send(["type": "pop"])
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Recent stderr output, for error reports.
    public var diagnostics: String { lock.withLock { stderrTail } }

    private func send(_ message: [String: Any]) {
        guard process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writeLock.withLock { try? input.fileHandleForWriting.write(contentsOf: data) }
    }

    private func receive(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty {
            handle(line: Data(line))
        }
    }

    struct Message: Decodable {
        let type: String
        let id: Int?
        let method: String?
        let params: HostJSON?
        let tree: [ViewNode]?
        let depth: Int?
        let message: String?
        let stack: String?
    }

    private func handle(line: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: line) else { return }
        switch message.type {
        case "ready":
            if let launch = lock.withLock({ launchMessage }) { send(launch) }
        case "render":
            continuation.yield(.render(tree: message.tree ?? [], depth: message.depth ?? 0))
        case "notify":
            continuation.yield(.notify(method: message.method ?? "", params: message.params ?? .null))
        case "request":
            guard let id = message.id, let method = message.method else { return }
            let params = message.params ?? .null
            let services = services
            let context = context
            Task {
                do {
                    let result = try await services.handle(method: method, params: params, context: context)
                    self.send(["type": "response", "id": id, "result": result.anyValue])
                } catch {
                    self.send(["type": "response", "id": id, "error": error.localizedDescription])
                }
            }
        case "done":
            continuation.yield(.done)
        case "error":
            continuation.yield(.error(message: message.message ?? "Unknown error", stack: message.stack ?? ""))
        default:
            break
        }
    }

    /// Splits a byte stream into lines (exposed for tests).
    public static func splitLines(_ buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
