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

    /// Third-party code Lizard didn't write or review.
    public var isExternal: Bool { source.isExternal }

    /// The extension's icon file, if it has one.
    public var iconURL: URL? {
        guard let icon = manifest.icon else { return nil }
        let url = assetsDirectory.appending(path: icon)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        guard Self.isSafeName(name) else { return nil }
        return load(root.appending(path: name, directoryHint: .isDirectory))
    }

    private func load(_ directory: URL) -> InstalledExtension? {
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        guard let manifest = try? ExtensionManifest.load(from: package) else { return nil }
        let source = (try? Data(contentsOf: directory.appending(path: "source.json"))).flatMap { try? JSONDecoder().decode(ExtensionSource.self, from: $0) }
            ?? .folder(path: package.path)
        return InstalledExtension(name: directory.lastPathComponent, manifest: manifest, directory: directory, source: source)
    }

    // MARK: Install

    /// Installs from a local folder, a GitHub location (`owner/repo[/path][@ref]`, a github.com URL)
    /// or a bare name from Raycast's public catalog (`google-translate`).
    @discardableResult
    public func install(_ request: String, builtIn: Bool = false) async throws -> InstalledExtension {
        let expanded = (request as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            return try await installFolder(URL(filePath: expanded), source: builtIn ? .builtIn(path: expanded) : .folder(path: expanded))
        }
        guard let location = GitHubLocation.parse(request) else {
            throw ExtensionHostError.download("“\(request)” isn't a folder, a GitHub repo (owner/repo) or an extension name.")
        }
        return try await install(location)
    }

    @discardableResult
    public func install(_ location: GitHubLocation) async throws -> InstalledExtension {
        log("Looking up \(location.display)…")
        // Pin to the newest commit that touched this folder: the same commit update checks compare against.
        var commit = try await GitHubAPI.latestCommit(touching: location)
        if commit == nil { commit = try await GitHubAPI.resolveCommit(location) }
        guard let commit else { throw ExtensionHostError.download("couldn't resolve \(location.display)") }
        let staging = try await GitHubAPI.downloadFolder(location, commit: commit, log: log)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.fileExists(atPath: staging.appending(path: "package.json").path) else {
            throw ExtensionHostError.download("\(location.display) has no package.json. Point to the extension's folder (owner/repo/path).")
        }
        return try await installFolder(staging, source: .github(location, commit: commit))
    }

    public func uninstall(_ name: String) throws {
        guard Self.isSafeName(name) else { throw ExtensionHostError.notInstalled(name) }
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func installFolder(_ folder: URL, source: ExtensionSource) async throws -> InstalledExtension {
        let manifest = try ExtensionManifest.load(from: folder)
        let directory = try installDirectory(for: manifest)
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log("Copying \(manifest.title)…")
        // Fresh copy of the sources; keep node_modules (and the user's data) across updates.
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

    /// `package.json` comes from third parties (GitHub, `.lizardext` files, Raycast), and its
    /// `name` and command names become paths under `root`. A name such as `../../Documents` would
    /// otherwise make an install copy over (and an update delete) folders outside Lizard's data.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name != "." && name != ".."
            && name.range(of: #"^[A-Za-z0-9._@-]+$"#, options: .regularExpression) != nil
    }

    private func installDirectory(for manifest: ExtensionManifest) throws -> URL {
        guard Self.isSafeName(manifest.name) else {
            throw ExtensionHostError.buildFailed("“\(manifest.name)” isn't a valid extension name (use letters, digits and dashes).")
        }
        if let bad = manifest.commands.first(where: { !Self.isSafeName($0.name) }) {
            throw ExtensionHostError.buildFailed("“\(bad.name)” isn't a valid command name (use letters, digits and dashes).")
        }
        return root.appending(path: manifest.name, directoryHint: .isDirectory)
    }

    // MARK: Updates

    /// Extensions whose GitHub folder has a newer commit than the installed one: name → new commit.
    public func availableUpdates() async -> [String: String] {
        var updates: [String: String] = [:]
        for item in installed() {
            guard let location = item.source.github, let installedCommit = item.source.commit else { continue }
            if let latest = try? await GitHubAPI.latestCommit(touching: location), latest != installedCommit {
                updates[item.name] = latest
            }
        }
        return updates
    }

    /// Re-installs from the same GitHub location at its newest commit, keeping preferences and data.
    @discardableResult
    public func update(_ name: String) async throws -> InstalledExtension {
        guard let item = extensionNamed(name), let location = item.source.github else { throw ExtensionHostError.notInstalled(name) }
        return try await install(location)
    }

    // MARK: Raycast import

    /// Extensions installed in Raycast on this Mac (already compiled by Raycast).
    public nonisolated static func raycastExtensions() -> [(folder: URL, manifest: ExtensionManifest)] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/raycast/extensions", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let found = folders.compactMap { folder -> (folder: URL, manifest: ExtensionManifest)? in
            guard folder.lastPathComponent != "node_modules", let manifest = try? ExtensionManifest.load(from: folder) else { return nil }
            return (folder, manifest)
        }
        // A store install and a developer copy share a name: list it once, newest copy wins.
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let newest = Dictionary(grouping: found, by: \.manifest.name).compactMap { $0.value.max { modified($0.folder) < modified($1.folder) } }
        return newest.sorted { $0.manifest.title < $1.manifest.title }
    }

    /// Imports a Raycast-installed extension: its compiled command bundles run as-is (no network, no build).
    @discardableResult
    public func importFromRaycast(_ folder: URL) async throws -> InstalledExtension {
        let manifest = try ExtensionManifest.load(from: folder)
        let directory = try installDirectory(for: manifest)
        let package = directory.appending(path: "package", directoryHint: .isDirectory)
        let build = directory.appending(path: "build", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: package)
        try? FileManager.default.removeItem(at: build)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        log("Importing \(manifest.title) from Raycast…")
        let copy = try await ProcessRunner.run("/usr/bin/rsync", ["-a", folder.path + "/", package.path + "/"], timeout: .seconds(300))
        guard copy.succeeded else { throw ExtensionHostError.buildFailed(copy.tail(5)) }
        for command in manifest.commands {
            let bundle = package.appending(path: "\(command.name).js")
            if FileManager.default.fileExists(atPath: bundle.path) {
                try FileManager.default.copyItem(at: bundle, to: build.appending(path: "\(command.name).js"))
            }
        }
        try JSONEncoder().encode(ExtensionSource.raycastImport(path: folder.path)).write(to: directory.appending(path: "source.json"))
        guard let installed = load(directory) else { throw ExtensionHostError.buildFailed("manifest unreadable after import") }
        return installed
    }

    // MARK: Export

    /// Writes `<name>.lizardext` (a zip of the extension's source, no data, no dependencies) into `folder`.
    public func exportPackage(_ name: String, to folder: URL) async throws -> URL {
        guard let item = extensionNamed(name) else { throw ExtensionHostError.notInstalled(name) }
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-export-\(UUID().uuidString)/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let copy = try await ProcessRunner.run(
            "/usr/bin/rsync", ["-a", "--exclude", "node_modules", "--exclude", ".git", item.packageDirectory.path + "/", staging.path + "/"], timeout: .seconds(120))
        guard copy.succeeded else { throw ExtensionHostError.buildFailed(copy.tail(5)) }
        let target = folder.appending(path: "\(name).lizardext")
        try? FileManager.default.removeItem(at: target)
        let zip = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, target.path], timeout: .seconds(120))
        guard zip.succeeded else { throw ExtensionHostError.buildFailed(zip.tail(5)) }
        return target
    }

    /// Installs a `.lizardext` file someone shared.
    @discardableResult
    public func installPackage(_ file: URL) async throws -> InstalledExtension {
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path], timeout: .seconds(120))
        guard unzip.succeeded else { throw ExtensionHostError.download("not a Lizard extension file") }
        let candidates = [staging] + ((try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
        guard let folder = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "package.json").path) }) else {
            throw ExtensionHostError.download("the file has no package.json")
        }
        return try await installFolder(folder, source: .folder(path: file.path))
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
