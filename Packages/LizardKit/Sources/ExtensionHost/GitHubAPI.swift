import Foundation
import LizardCore

/// The GitHub calls extension installs and update checks need: resolve a commit, download one
/// folder (tree API + raw files, never a full clone), find the latest commit touching a folder.
/// Requests carry the GitHub CLI's token when signed in (higher rate limits, private repos).
enum GitHubAPI {
    static func json(_ path: String) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = await token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ExtensionHostError.download(
                status == 404 ? "not found on GitHub (check the repo, folder and branch)"
                    : status == 403 || status == 429 ? "GitHub rate limit reached — sign in to GitHub in Settings › Accounts" : "GitHub HTTP \(status)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func token() async -> String? {
        guard let status = await GitHubCLI.status(), status.isSignedIn,
            let result = try? await ProcessRunner.run(status.executable, ["auth", "token"], environment: GitHubCLI.environment(managed: status.isManaged), timeout: .seconds(10)),
            result.succeeded
        else { return nil }
        let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }

    /// The commit SHA the ref (or default branch) points at.
    static func resolveCommit(_ location: GitHubLocation) async throws -> String {
        let ref = location.ref ?? "HEAD"
        guard let commit = try await json("repos/\(location.owner)/\(location.repo)/commits/\(encode(ref))") as? [String: Any],
            let sha = commit["sha"] as? String
        else { throw ExtensionHostError.download("couldn't resolve \(location.display)") }
        return sha
    }

    /// Newest commit on the ref that changed the extension's folder.
    static func latestCommit(touching location: GitHubLocation) async throws -> String? {
        var query = "repos/\(location.owner)/\(location.repo)/commits?per_page=1"
        if let ref = location.ref { query += "&sha=\(encode(ref))" }
        if !location.path.isEmpty { query += "&path=\(encode(location.path))" }
        return ((try await json(query) as? [[String: Any]])?.first)?["sha"] as? String
    }

    /// Downloads `location.path` at `commit` into a temporary folder and returns it.
    static func downloadFolder(_ location: GitHubLocation, commit: String, log: @Sendable (String) -> Void) async throws -> URL {
        let treeRef = location.path.isEmpty ? commit : "\(commit):\(location.path)"
        guard let tree = try await json("repos/\(location.owner)/\(location.repo)/git/trees/\(encode(treeRef))?recursive=1") as? [String: Any],
            let entries = tree["tree"] as? [[String: Any]]
        else { throw ExtensionHostError.download("\(location.display) wasn't found") }
        let files = entries.filter { ($0["type"] as? String) == "blob" }.compactMap { $0["path"] as? String }
            .filter { !$0.hasPrefix("node_modules/") && !$0.hasPrefix("metadata/") && !$0.hasPrefix("media/") && !$0.hasPrefix(".github/") }
        guard files.count <= 2_000 else { throw ExtensionHostError.download("that folder has \(files.count) files — point to a single extension's folder") }
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        log("Downloading \(files.count) files…")
        let prefix = location.path.isEmpty ? "" : location.path + "/"
        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            for file in files {
                if active >= 8 {
                    try await group.next()
                    active -= 1
                }
                active += 1
                group.addTask {
                    let encodedPath = (prefix + file).split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
                    let raw = URL(string: "https://raw.githubusercontent.com/\(location.owner)/\(location.repo)/\(commit)/\(encodedPath)")!
                    let (data, response) = try await URLSession.shared.data(from: raw)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtensionHostError.download("\(file): HTTP error") }
                    let target = staging.appending(path: file)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                }
            }
            try await group.waitForAll()
        }
        return staging
    }
}
