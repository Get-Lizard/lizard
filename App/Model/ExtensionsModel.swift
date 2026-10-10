import AppKit
import ExtensionHost
import Foundation
import LizardCore
import Observation

/// Installed Raycast-compatible extensions: install/remove, launching commands, menu-bar
/// commands as status items, and the default GitHub integration.
@Observable
@MainActor
final class ExtensionsModel {
    struct Suggestion {
        let name: String
        let title: String
        let detail: String
        /// Store name or a built-in folder.
        let source: String
    }

    enum GitHubDefaultState: Equatable {
        case notInstalled, installing, installed, failed(String)

        var detail: String {
            switch self {
            case .notInstalled: "Review requests and your open PRs in the menu bar, plus search and an activity inbox."
            case .installing: "Installing…"
            case .installed: "In your menu bar. Uses your GitHub sign-in through the GitHub CLI."
            case .failed(let message): message
            }
        }
    }

    static let githubExtension = "github-review-requests"
    private static let enabledMenuBarKey = "Lizard.EnabledMenuBarCommands"

    private(set) var installed: [InstalledExtension] = []
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var githubDefaultState = GitHubDefaultState.notInstalled
    /// Extension subtitles set with updateCommandMetadata, by "extension/command".
    private(set) var subtitles: [String: String] = [:]

    let store: ExtensionStore
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var menuBars: [String: MenuBarCommandController] = [:]

    init() {
        store = ExtensionStore()
    }

    /// Lizard's own extensions folder (`Extensions/` in the repo for development, or the app bundle).
    static var builtInRoot: URL? {
        if let bundled = Bundle.main.resourceURL?.appending(path: "Extensions"), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Extensions")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    static var suggested: [Suggestion] {
        var list = [
            Suggestion(name: githubExtension, title: "GitHub Review Requests", detail: "PRs waiting on you, in the menu bar (GitHub CLI sign-in).", source: githubExtension),
        ]
        let builtIns: [(String, String, String)] = [
            ("lizard-translate", "Translate", "Translate text or the current selection."),
            ("lizard-slack", "Slack", "Jump to favourite channels and people."),
            ("lizard-1password", "1Password", "Search items and copy passwords with the 1Password CLI."),
            ("lizard-apple-notes", "Apple Notes", "Search and create notes."),
            ("lizard-warp", "Warp", "Open Warp here, or a launch configuration."),
            ("lizard-apple-reminders", "Apple Reminders", "Today's reminders, quick add, menu-bar count."),
            ("lizard-kill-process", "Kill Process", "Find and stop runaway processes."),
        ]
        if let root = builtInRoot {
            for (folder, title, detail) in builtIns where FileManager.default.fileExists(atPath: root.appending(path: folder).path) {
                list.append(Suggestion(name: folder, title: title, detail: detail, source: root.appending(path: folder).path))
            }
        }
        return list
    }

    func start() {
        Task {
            await reload()
            startEnabledMenuBars()
        }
    }

    func reload() async {
        installed = await store.installed()
        githubDefaultState = installed.contains { $0.name == Self.githubExtension } ? .installed : (githubDefaultState == .installing ? .installing : .notInstalled)
    }

    // MARK: Install

    func install(_ source: String) {
        guard !isBusy, !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isBusy = true
        message = "Installing \(source)…"
        Task {
            defer { isBusy = false }
            do {
                let installedExtension = try await store.install(source, builtIn: source.hasPrefix("/"))
                message = "Installed \(installedExtension.title)."
                await reload()
                // Menu-bar commands appear right away.
                for command in installedExtension.commands where command.mode == .menuBar && command.disabledByDefault != true {
                    setMenuBar(installedExtension.name, command.name, enabled: true)
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func uninstall(_ name: String) {
        for key in menuBars.keys where key.hasPrefix("\(name)/") {
            menuBars.removeValue(forKey: key)?.stop()
        }
        Task {
            try? await store.uninstall(name)
            await reload()
        }
    }

    /// GitHub Review Requests, preset to sign in through the GitHub CLI, menu bar on.
    func installGitHubDefault(accounts: AccountsModel) {
        guard githubDefaultState != .installing else { return }
        githubDefaultState = .installing
        Task {
            do {
                if await store.extensionNamed(Self.githubExtension) == nil {
                    try await store.install(Self.githubExtension)
                }
                let status = await GitHubCLI.status()
                try await store.setPreferences(Self.githubExtension, values: [
                    "authMethod": .string("gh"),
                    "ghPath": status.map { .string($0.executable) } ?? nil,
                ])
                await reload()
                setMenuBar(Self.githubExtension, "actionablePullRequests", enabled: true)
                githubDefaultState = .installed
                UserDefaults.standard.set(true, forKey: Preferences.githubOfferedKey)
            } catch {
                githubDefaultState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Running commands

    /// Extra environment for extension processes (Lizard's own GitHub CLI login).
    func processEnvironment() async -> [String: String] {
        if let status = await GitHubCLI.status(), status.isManaged { return GitHubCLI.environment(managed: true) }
        return [:]
    }

    func makeRuntime(_ installedExtension: InstalledExtension, _ command: ExtensionManifest.Command, launchType: String = "userInitiated") async throws -> ExtensionRuntime {
        guard let app else { throw ExtensionHostError.launchFailed("app not ready") }
        let runtime = ExtensionRuntime(
            context: ExtensionContext(extensionName: installedExtension.name, commandName: command.name), services: AppHostServices(app: app))
        try runtime.start(
            bundle: installedExtension.bundle(for: command.name), command: command, extensionDirectory: installedExtension.packageDirectory,
            assetsPath: installedExtension.assetsDirectory, supportPath: installedExtension.supportDirectory.appending(path: command.name),
            author: installedExtension.manifest.author, preferences: await store.preferences(for: installedExtension, command: command),
            launchType: launchType, environment: await processEnvironment())
        return runtime
    }

    /// Opens a command from the launcher.
    func launch(_ installedExtension: InstalledExtension, _ command: ExtensionManifest.Command) {
        guard let app else { return }
        Task {
            let missing = await store.missingRequiredPreferences(for: installedExtension, command: command)
            if !missing.isEmpty {
                app.showHUD("Set \(missing.map { $0.title ?? $0.name }.joined(separator: ", ")) in Settings › Extensions")
                app.openSettings()
                return
            }
            do {
                switch command.mode {
                case .menuBar:
                    setMenuBar(installedExtension.name, command.name, enabled: true)
                    menuBars["\(installedExtension.name)/\(command.name)"]?.refresh()
                    app.hideLauncher()
                case .noView:
                    app.hideLauncher()
                    let runtime = try await makeRuntime(installedExtension, command)
                    Task { await self.drain(runtime) }
                case .view:
                    let runtime = try await makeRuntime(installedExtension, command)
                    let session = ExtensionSession(installed: installedExtension, command: command, runtime: runtime)
                    session.onNotify = { [weak self] method, params in self?.handleNotify(method, params, extensionName: installedExtension.name, command: command.name) }
                    session.listen()
                    app.launcher.push(.extensionView(session))
                }
            } catch {
                app.showHUD(error.localizedDescription)
            }
        }
    }

    /// Runs a no-view command to completion, handling its notifications.
    private func drain(_ runtime: ExtensionRuntime) async {
        for await event in runtime.events {
            switch event {
            case .notify(let method, let params):
                handleNotify(method, params, extensionName: runtime.context.extensionName, command: runtime.context.commandName)
            case .done:
                runtime.stop()
            case .error(let message, _):
                app?.showHUD(message)
            default:
                break
            }
        }
    }

    func handleNotify(_ method: String, _ params: HostJSON, extensionName: String, command: String) {
        guard let app else { return }
        switch method {
        case "hud":
            app.showHUD(params["title"]?.string ?? "")
        case "toast.show":
            if params["style"]?.string == "FAILURE" || !app.isLauncherVisible {
                app.showHUD([params["title"]?.string, params["message"]?.string].compactMap { $0 }.joined(separator: " — "))
            }
        case "closeMainWindow":
            app.hideLauncher()
        case "popToRoot":
            app.launcher.resetToRoot()
        case "updateCommandMetadata":
            subtitles["\(extensionName)/\(command)"] = params["subtitle"]?.string
        case "openPreferences":
            app.openSettings()
        default:
            break
        }
    }

    // MARK: Menu bar commands

    private var enabledMenuBars: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.enabledMenuBarKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.enabledMenuBarKey) }
    }

    func isMenuBarEnabled(_ extensionName: String, _ command: String) -> Bool {
        enabledMenuBars.contains("\(extensionName)/\(command)")
    }

    func setMenuBar(_ extensionName: String, _ commandName: String, enabled: Bool) {
        let key = "\(extensionName)/\(commandName)"
        var set = enabledMenuBars
        if enabled { set.insert(key) } else { set.remove(key) }
        enabledMenuBars = set
        if enabled {
            guard menuBars[key] == nil, let installedExtension = installed.first(where: { $0.name == extensionName }),
                let command = installedExtension.commands.first(where: { $0.name == commandName }) else { return }
            let controller = MenuBarCommandController(installed: installedExtension, command: command, model: self)
            menuBars[key] = controller
            controller.start()
        } else {
            menuBars.removeValue(forKey: key)?.stop()
        }
    }

    private func startEnabledMenuBars() {
        for key in enabledMenuBars {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            setMenuBar(parts[0], parts[1], enabled: true)
        }
    }

    func stopAll() {
        for controller in menuBars.values { controller.stop() }
    }

    /// Searchable commands for the launcher.
    var commands: [(InstalledExtension, ExtensionManifest.Command)] {
        installed.flatMap { item in item.commands.map { (item, $0) } }
    }
}
