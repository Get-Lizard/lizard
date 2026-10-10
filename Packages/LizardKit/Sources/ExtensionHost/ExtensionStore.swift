import Foundation
import LizardCore

/// An extension on disk.
///
/// Layout under `Application Support/Lizard/Extensions/<name>/`:
/// `package/` (the source + node_modules), `build/<command>.js`, `support/` (its storage),
/// `preferences.json`, `source.json`.
public struct InstalledExtension: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let manifest: ExtensionManifest
    public let directory: URL
    public let source: ExtensionSource

    public var title: String { manifest.title }
    public var commands: [ExtensionManifest.Command] { manifest.commands }
    public var packageDirectory: URL { directory.appending(path: "package", directoryHint: .isDirectory) }
    public var buildDirectory: URL { directory.appending(path: "build", directoryHint: .isDirectory) }
    public var supportDirectory: URL { directory.appending(path: "support", directoryHint: .isDirectory) }
    public var assetsDirectory: URL { packageDirectory.appending(path: "assets", directoryHint: .isDirectory) }

    public func bundle(for command: String) -> URL { buildDirectory.appending(path: "\(command).js") }

    /// The extension's icon file, if it has one.
    public var iconURL: URL? {
        guard let icon = manifest.icon else { return nil }
        let url = assetsDirectory.appending(path: icon)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Where an extension came from.
public enum ExtensionSource: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A folder in raycast/extensions, pinned to a commit.
    case store(name: String, commit: String)
    case folder(path: String)
    /// Shipped inside Lizard.
    case builtIn(path: String)

    public var description: String {
        switch self {
        case .store(_, let commit): "Raycast Store @ \(commit.prefix(7))"
        case .folder(let path): path
        case .builtIn: "Built in"
        }
    }
}

/// Installs, builds and lists extensions; keeps their preferences.
public actor ExtensionStore {
    public let root: URL
    private let log: @Sendable (String) -> Void

    public init(root: URL = AppPaths.applicationSupport.appending(path: "Extensions", directoryHint: .isDirectory), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = root
        self.log = log
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Listing

    public func installed() -> [InstalledExtension] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap(load).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func extensionNamed(_ name: String) -> InstalledExtension? {
        load(root.appending(path: name, directoryHint: .isDirectory))
    }

    private func load(_ directory: URL) -> InstalledExtension? {
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        guard let manifest = try? ExtensionManifest.load(from: package) else { return nil }
        let source = (try? Data(contentsOf: directory.appending(path: "source.json"))).flatMap { try? JSONDecoder().decode(ExtensionSource.self, from: $0) }
            ?? .folder(path: package.path)
        return InstalledExtension(name: directory.lastPathComponent, manifest: manifest, directory: directory, source: source)
    }

    // MARK: Install

    /// Installs from a folder path, a built-in folder, or a raycast/extensions name ("google-translate").
    @discardableResult
    public func install(_ request: String, builtIn: Bool = false) async throws -> InstalledExtension {
        let expanded = (request as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            return try await installFolder(URL(filePath: expanded), source: builtIn ? .builtIn(path: expanded) : .folder(path: expanded))
        }
        return try await installFromStore(request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public func uninstall(_ name: String) throws {
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func installFolder(_ folder: URL, source: ExtensionSource) async throws -> InstalledExtension {
        let manifest = try ExtensionManifest.load(from: folder)
        let directory = root.appending(path: manifest.name, directoryHint: .isDirectory)
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log("Copying \(manifest.title)…")
        // Fresh copy of the sources; keep node_modules if the lockfile didn't change.
        let staging = directory.appending(path: "package.new", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        let copy = try await ProcessRunner.run("/usr/bin/rsync", ["-a", "--exclude", "node_modules", "--exclude", ".git", folder.path + "/", staging.path + "/"], timeout: .seconds(120))
        guard copy.succeeded else { throw ExtensionHostError.buildFailed(copy.tail(5)) }
        if FileManager.default.fileExists(atPath: package.appending(path: "node_modules").path) {
            try? FileManager.default.moveItem(at: package.appending(path: "node_modules"), to: staging.appending(path: "node_modules"))
        }
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.moveItem(at: staging, to: package)
        try JSONEncoder().encode(source).write(to: directory.appending(path: "source.json"))
        try await build(directory: directory)
        guard let installed = load(directory) else { throw ExtensionHostError.buildFailed("manifest unreadable after install") }
        return installed
    }

    /// Downloads one extension folder from raycast/extensions at the current `main` commit
    /// (tree API + raw files — no full clone of the huge repository).
    private func installFromStore(_ name: String) async throws -> InstalledExtension {
        guard name.range(of: #"^[a-z0-9][a-z0-9-_.]*$"#, options: .regularExpression) != nil else {
            throw ExtensionHostError.download("“\(name)” isn't a valid extension name.")
        }
        log("Looking up \(name) in the Raycast Store…")
        let commit = try await Self.latestCommit()
        let path = "extensions/\(name)"
        let treeURL = URL(string: "https://api.github.com/repos/raycast/extensions/git/trees/\(commit)%3A\(path.replacingOccurrences(of: "/", with: "%2F"))?recursive=1")!
        let tree = try await Self.githubJSON(treeURL)
        guard let entries = tree["tree"] as? [[String: Any]] else { throw ExtensionHostError.download("“\(name)” wasn't found in raycast/extensions.") }
        let files = entries.filter { ($0["type"] as? String) == "blob" }.compactMap { $0["path"] as? String }
            .filter { !$0.hasPrefix("node_modules/") && !$0.hasPrefix("metadata/") && !$0.hasPrefix("media/") }
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        log("Downloading \(files.count) files…")
        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            for file in files {
                if active >= 8 {
                    try await group.next()
                    active -= 1
                }
                active += 1
                group.addTask {
                    let raw = URL(string: "https://raw.githubusercontent.com/raycast/extensions/\(commit)/\(path)/\(file)")!
                    let (data, response) = try await URLSession.shared.data(from: raw)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtensionHostError.download("\(file): HTTP error") }
                    let target = staging.appending(path: file)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                }
            }
            try await group.waitForAll()
        }
        return try await installFolder(staging, source: .store(name: name, commit: commit))
    }

    static func latestCommit() async throws -> String {
        let json = try await githubJSON(URL(string: "https://api.github.com/repos/raycast/extensions/commits/main")!)
        guard let sha = json["sha"] as? String else { throw ExtensionHostError.download("couldn't read the latest commit") }
        return sha
    }

    /// GitHub API call, authenticated with the GitHub CLI's token when available (higher limits).
    static func githubJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let status = await GitHubCLI.status(), status.isSignedIn,
            let token = try? await ProcessRunner.run(status.executable, ["auth", "token"], environment: GitHubCLI.environment(managed: status.isManaged), timeout: .seconds(10)),
            token.succeeded {
            request.setValue("Bearer \(token.output.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ExtensionHostError.download(status == 404 ? "not found" : status == 403 ? "GitHub rate limit reached — sign in to GitHub in Settings › Accounts" : "HTTP \(status)")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Build

    /// `npm install` (production deps, no scripts) then bundle each command with the shim's builder.
    public func build(directory: URL) async throws {
        guard let node = ExtensionHostPaths.node else { throw ExtensionHostError.nodeMissing }
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        let npm = URL(filePath: node).deletingLastPathComponent().appending(path: "npm").path
        let hasDependencies = (try? JSONSerialization.jsonObject(with: Data(contentsOf: package.appending(path: "package.json"))) as? [String: Any])
            .flatMap { $0["dependencies"] as? [String: Any] }.map { !$0.isEmpty } ?? false
        if hasDependencies {
            log("Installing dependencies…")
            let install = try await ProcessRunner.run(
                FileManager.default.isExecutableFile(atPath: npm) ? npm : "npm",
                ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"],
                cwd: package, environment: ToolEnvironment.shared.environment(), timeout: .seconds(600))
            guard install.succeeded else { throw ExtensionHostError.buildFailed(install.tail(8)) }
        }
        log("Building commands…")
        let builder = ExtensionHostPaths.shimDirectory.appending(path: "build-extension.js")
        guard FileManager.default.fileExists(atPath: builder.path) else { throw ExtensionHostError.shimMissing(builder.path) }
        let buildDirectory = directory.appending(path: "build", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: buildDirectory)
        let result = try await ProcessRunner.run(
            node, [builder.path, package.path, buildDirectory.path], environment: ToolEnvironment.shared.environment(), timeout: .seconds(300))
        guard result.succeeded else { throw ExtensionHostError.buildFailed(result.tail(8)) }
    }

    // MARK: Preferences

    private func preferencesURL(_ name: String) -> URL { root.appending(path: name).appending(path: "preferences.json") }

    /// Saved values merged over the manifest defaults (extension-wide + command).
    public func preferences(for installed: InstalledExtension, command: ExtensionManifest.Command?) -> [String: HostJSON] {
        var values = installed.manifest.defaultPreferences(for: command)
        let saved = (try? Data(contentsOf: preferencesURL(installed.name))).flatMap { try? JSONDecoder().decode([String: HostJSON].self, from: $0) } ?? [:]
        let names = Set(installed.manifest.allPreferences(for: command).map(\.name))
        for (key, value) in saved where names.contains(key) { values[key] = value }
        return values
    }

    public func savedPreferences(_ name: String) -> [String: HostJSON] {
        (try? Data(contentsOf: preferencesURL(name))).flatMap { try? JSONDecoder().decode([String: HostJSON].self, from: $0) } ?? [:]
    }

    /// Merges `values` into the saved preferences (nil removes a key).
    public func setPreferences(_ name: String, values: [String: HostJSON?]) throws {
        var saved = savedPreferences(name)
        for (key, value) in values { saved[key] = value }
        try JSONEncoder().encode(saved).write(to: preferencesURL(name), options: .atomic)
    }

    /// Required preferences without a value (the command can't run until they're set).
    public func missingRequiredPreferences(for installed: InstalledExtension, command: ExtensionManifest.Command) -> [ExtensionManifest.Preference] {
        let values = preferences(for: installed, command: command)
        return installed.manifest.allPreferences(for: command).filter { preference in
            guard preference.required == true else { return false }
            guard let value = values[preference.name] else { return true }
            return value.string?.isEmpty ?? value.isNull
        }
    }
}
