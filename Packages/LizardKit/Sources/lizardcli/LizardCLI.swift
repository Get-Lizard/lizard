import AIEngine
import DevTools
import ExtensionHost
import Foundation
import LizardCore

/// Headless access to Lizard's engines, for testing without the app.
///   lizardcli ext install <name|path> | ext list | ext run <extension> <command> [--prefs k=v,...]
///   lizardcli transform <transform> <text> | apple-ai | gh-status
@main
struct LizardCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { return usage() }
        args.removeFirst()
        do {
            switch command {
            case "ext": try await ext(args)
            case "transform": try transform(args)
            case "apple-ai": await appleAI()
            case "gh-status": await ghStatus()
            case "gh-install":
                try await GitHubCLI.ensureInstalled { print("·", $0) }
                print("installed at \(GitHubCLI.managedExecutable.path)")
            default: usage()
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        print("""
            usage: lizardcli ext install <name|path> | ext list | ext run <extension> <command> [k=v ...]
                   lizardcli transform <\(TextTransform.allCases.map(\.rawValue).joined(separator: "|"))> <text>
                   lizardcli apple-ai | gh-status
            """)
    }

    static func ext(_ args: [String]) async throws {
        let store = ExtensionStore(log: { fputs("· \($0)\n", stderr) })
        switch args.first {
        case "install":
            guard args.count >= 2 else { return usage() }
            let installed = try await store.install(args[1])
            print("installed \(installed.name): \(installed.commands.map(\.name).joined(separator: ", "))")
        case "list":
            for item in await store.installed() {
                print("\(item.name)\t\(item.title)\t\(item.source)\t\(item.commands.map { "\($0.name)(\($0.mode.rawValue))" }.joined(separator: " "))")
            }
        case "run":
            guard args.count >= 3 else { return usage() }
            try await run(store: store, name: args[1], commandName: args[2], overrides: Array(args.dropFirst(3)))
        default:
            usage()
        }
    }

    /// Runs a command until its first settled render (or completion) and prints the JSON tree.
    static func run(store: ExtensionStore, name: String, commandName: String, overrides: [String]) async throws {
        guard let installed = await store.extensionNamed(name) else { throw ExtensionHostError.notInstalled(name) }
        guard let command = installed.commands.first(where: { $0.name == commandName }) else {
            throw ExtensionHostError.launchFailed("no command \(commandName)")
        }
        var preferences = await store.preferences(for: installed, command: command)
        for pair in overrides {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { preferences[parts[0]] = .string(parts[1]) }
        }
        let runtime = ExtensionRuntime(context: ExtensionContext(extensionName: name, commandName: commandName), services: CLIServices())
        var extra: [String: String] = [:]
        if let status = await GitHubCLI.status(), status.isManaged { extra = GitHubCLI.environment(managed: true) }
        try runtime.start(
            bundle: installed.bundle(for: commandName), command: command, extensionDirectory: installed.packageDirectory,
            assetsPath: installed.assetsDirectory, supportPath: installed.supportDirectory.appending(path: commandName),
            author: installed.manifest.author, preferences: preferences, environment: extra)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var lastTree: [ViewNode] = []
        let deadline = Task {
            try? await Task.sleep(for: .seconds(20))
            runtime.stop()
        }
        for await event in runtime.events {
            switch event {
            case .render(let tree, _):
                lastTree = tree
                // Settled when nothing reports isLoading.
                if !tree.contains(where: { isLoading($0) }) {
                    print(String(decoding: try encoder.encode(tree), as: UTF8.self))
                    runtime.stop()
                }
            case .notify(let method, let params):
                fputs("notify \(method) \(String(decoding: (try? JSONEncoder().encode(params)) ?? Data(), as: UTF8.self))\n", stderr)
            case .done:
                print("done")
                runtime.stop()
            case .error(let message, let stack):
                fputs("extension error: \(message)\n\(stack.prefix(1500))\n", stderr)
            case .exited:
                if !lastTree.isEmpty, lastTree.contains(where: { isLoading($0) }) {
                    print(String(decoding: try encoder.encode(lastTree), as: UTF8.self))
                }
            }
        }
        deadline.cancel()
    }

    static func isLoading(_ node: ViewNode) -> Bool {
        node.bool("isLoading") == true || node.children.contains(where: isLoading)
    }

    static func transform(_ args: [String]) throws {
        guard args.count >= 1, let transform = TextTransform(rawValue: args[0]) else { return usage() }
        print(try transform.apply(args.dropFirst().joined(separator: " ")))
    }

    static func appleAI() async {
        print(AppleIntelligence.isAvailable ? "available" : (AppleIntelligence.unavailableReason ?? "unavailable"))
        if let triage = await AppleIntelligence.triage("what does EPIPE mean") { print("triage:", triage.intent, triage.looksLikeQuestion) }
    }

    static func ghStatus() async {
        if let status = await GitHubCLI.status() {
            print("gh: \(status.executable) managed=\(status.isManaged) user=\(status.username ?? "-")")
        } else {
            print("gh: not installed")
        }
    }
}

/// Minimal services for headless runs.
struct CLIServices: HostServices {
    func handle(method: String, params: HostJSON, context: ExtensionContext) async throws -> HostJSON {
        fputs("request \(method)\n", stderr)
        switch method {
        case "confirmAlert": return .bool(true)
        case "applications": return .array([])
        case "selectedText": return .null
        default: return .null
        }
    }
}
