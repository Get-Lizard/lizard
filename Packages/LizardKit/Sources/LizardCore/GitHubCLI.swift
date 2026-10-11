import Foundation
import Synchronization

/// GitHub through the official GitHub CLI (`gh`) only: no API keys or tokens to paste.
///
/// - If `gh` is already installed and signed in, Lizard just uses it.
/// - Otherwise Lizard downloads GitHub's official CLI into its own folder (once) and runs its
///   browser sign-in (device code) with a Lizard-owned config folder, which stays so that
///   extensions can call `gh` / `gh auth token` later.
/// Ported from Cocoon's `GitHubLogin`; the difference is that the login persists for extensions.
public enum GitHubCLI {
    public enum Event: Sendable {
        /// Open this page and enter the code (the code is also on the clipboard).
        case visit(url: URL, code: String)
        case status(String)
    }

    public enum CLIError: Error, LocalizedError {
        case download(String), failed(String)

        public var errorDescription: String? {
            switch self {
            case .download(let detail): "Couldn't get GitHub's command-line tool: \(detail)"
            case .failed(let detail): "GitHub sign-in didn't finish. \(detail)"
            }
        }
    }

    public struct Status: Sendable, Equatable {
        public var executable: String
        public var username: String?
        public var isManaged: Bool
        public var isSignedIn: Bool { username != nil }

        public init(executable: String, username: String?, isManaged: Bool) {
            self.executable = executable
            self.username = username
            self.isManaged = isManaged
        }
    }

    /// No spaces in the path (some tools mishandle them).
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lizard/gh", directoryHint: .isDirectory)
    }
    public static var managedExecutable: URL { installDirectory.appending(path: "bin/gh") }
    public static var managedConfig: URL {
        AppPaths.ensure(AppPaths.applicationSupport.appending(path: "gh-config", directoryHint: .isDirectory))
    }

    static let quiet = ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"]

    /// Environment for anything that runs `gh` on Lizard's behalf (extensions included).
    public static func environment(managed: Bool) -> [String: String] {
        var env = quiet
        if managed {
            env["GH_CONFIG_DIR"] = managedConfig.path
            let path = ToolEnvironment.shared.environment()["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = managedExecutable.deletingLastPathComponent().path + ":" + path
        }
        return env
    }

    /// Which `gh` Lizard uses and who is signed in: the user's own signed-in `gh` wins, then Lizard's.
    public static func status() async -> Status? {
        if let system = ToolEnvironment.shared.which("gh"), let user = await username(executable: system, managed: false) {
            return Status(executable: system, username: user, isManaged: false)
        }
        if FileManager.default.isExecutableFile(atPath: managedExecutable.path) {
            let user = await username(executable: managedExecutable.path, managed: true)
            return Status(executable: managedExecutable.path, username: user, isManaged: true)
        }
        if let system = ToolEnvironment.shared.which("gh") {
            return Status(executable: system, username: nil, isManaged: false)
        }
        return nil
    }

    static func username(executable: String, managed: Bool) async -> String? {
        guard let result = try? await ProcessRunner.run(
            executable, ["api", "user", "--jq", ".login"], environment: environment(managed: managed), timeout: .seconds(20)),
            result.succeeded
        else { return nil }
        let login = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty || login.contains(" ") ? nil : login
    }

    /// Downloads the latest official macOS build from GitHub's releases.
    public static func ensureInstalled(onEvent: @Sendable (Event) -> Void) async throws {
        guard !FileManager.default.isExecutableFile(atPath: managedExecutable.path) else { return }
        onEvent(.status("Getting GitHub's command-line tool (one time)…"))
        let release = URL(string: "https://api.github.com/repos/cli/cli/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: release)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let asset = (json["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix("macOS_arm64.zip") == true }),
            let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw CLIError.download("no macOS download found") }
        let (zip, _) = try await URLSession.shared.download(from: link)
        let staging = FileManager.default.temporaryDirectory.appending(path: "gh-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: zip)
        }
        let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], timeout: .seconds(120))
        guard unzip.succeeded,
            let folder = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("gh_") })
        else { throw CLIError.download(unzip.tail(3)) }
        try? FileManager.default.removeItem(at: installDirectory)
        try FileManager.default.createDirectory(at: installDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: installDirectory)
        guard FileManager.default.isExecutableFile(atPath: managedExecutable.path) else { throw CLIError.download("the tool is missing after unpacking") }
    }

    /// Browser sign-in (device code). Returns the final status.
    @discardableResult
    public static func signIn(onEvent: @escaping @Sendable (Event) -> Void) async throws -> Status {
        if let current = await status(), current.isSignedIn { return current }
        try await ensureInstalled(onEvent: onEvent)
        onEvent(.status("Opening GitHub in your browser…"))
        let code = Mutex<String?>(nil)
        let announced = Mutex(false)
        let login = try await ProcessRunner.run(
            managedExecutable.path,
            ["auth", "login", "--web", "--hostname", "github.com", "--git-protocol", "https", "--skip-ssh-key", "--scopes", "repo,read:org,notifications"],
            environment: environment(managed: true), timeout: .seconds(900)
        ) { line in
            if let found = deviceCode(in: line) { code.withLock { $0 = found } }
            let url = deviceURL(in: line)
            if let value = code.withLock({ $0 }), announced.withLock({ let first = !$0; $0 = true; return first }) {
                onEvent(.visit(url: url, code: value))
            }
        }
        guard login.succeeded else { throw CLIError.failed(login.tail(2)) }
        guard let final = await status(), final.isSignedIn else { throw CLIError.failed("GitHub didn't confirm the account.") }
        return final
    }

    /// The one-time code in a `gh auth login --web` line: "First copy your one-time code: AB12-CD34"
    /// or "! One-time code (AB12-CD34) copied to clipboard".
    static func deviceCode(in line: String) -> String? {
        guard line.lowercased().contains("code"), let match = line.firstMatch(of: /\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/) else { return nil }
        return String(match.1)
    }

    /// The device-login page named in the line, or GitHub's standard one.
    static func deviceURL(in line: String) -> URL {
        line.firstMatch(of: /https:\/\/github\.com\/login\/device\S*/).flatMap { URL(string: String($0.0)) }
            ?? URL(string: "https://github.com/login/device")!
    }

    /// Signs out of Lizard's own login (never touches a `gh` the user set up themselves).
    public static func signOut() async {
        guard FileManager.default.isExecutableFile(atPath: managedExecutable.path) else { return }
        _ = try? await ProcessRunner.run(
            managedExecutable.path, ["auth", "logout", "--hostname", "github.com"], environment: environment(managed: true), timeout: .seconds(20))
    }
}
