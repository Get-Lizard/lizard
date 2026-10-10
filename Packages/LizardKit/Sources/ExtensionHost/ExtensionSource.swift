import Foundation

/// Where an extension came from. Lizard has no store: extensions live in GitHub repos (any
/// owner), local folders, Raycast imports, or ship inside Lizard.
public enum ExtensionSource: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A folder in a GitHub repo, pinned to the commit it was installed from.
    case github(GitHubLocation, commit: String)
    case folder(path: String)
    /// Copied from Raycast's installed extensions (already compiled).
    case raycastImport(path: String)
    /// Shipped inside Lizard.
    case builtIn(path: String)

    /// Anything not made by Lizard: shown with an "External" badge.
    public var isExternal: Bool {
        if case .builtIn = self { return false }
        return true
    }

    public var github: GitHubLocation? {
        if case .github(let location, _) = self { return location }
        return nil
    }

    public var commit: String? {
        if case .github(_, let commit) = self { return commit }
        return nil
    }

    public var description: String {
        switch self {
        case .github(let location, let commit): "\(location.display) @ \(commit.prefix(7))"
        case .folder(let path): path
        case .raycastImport: "Imported from Raycast"
        case .builtIn: "Built in"
        }
    }

    // Older installs stored `store(name:commit:)` for raycast/extensions; read them as GitHub.
    enum CodingKeys: String, CodingKey { case github, folder, raycastImport, builtIn, store }
    enum NestedKeys: String, CodingKey { case _0, commit, path, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .github) {
            self = .github(try nested.decode(GitHubLocation.self, forKey: ._0), commit: try nested.decode(String.self, forKey: .commit))
        } else if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .store) {
            let name = try nested.decode(String.self, forKey: .name)
            self = .github(.raycastCatalog(name), commit: try nested.decode(String.self, forKey: .commit))
        } else if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .folder) {
            self = .folder(path: try nested.decode(String.self, forKey: .path))
        } else if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .raycastImport) {
            self = .raycastImport(path: try nested.decode(String.self, forKey: .path))
        } else {
            let nested = try container.nestedContainer(keyedBy: NestedKeys.self, forKey: .builtIn)
            self = .builtIn(path: try nested.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .github(let location, let commit):
            var nested = container.nestedContainer(keyedBy: NestedKeys.self, forKey: .github)
            try nested.encode(location, forKey: ._0)
            try nested.encode(commit, forKey: .commit)
        case .folder(let path):
            var nested = container.nestedContainer(keyedBy: NestedKeys.self, forKey: .folder)
            try nested.encode(path, forKey: .path)
        case .raycastImport(let path):
            var nested = container.nestedContainer(keyedBy: NestedKeys.self, forKey: .raycastImport)
            try nested.encode(path, forKey: .path)
        case .builtIn(let path):
            var nested = container.nestedContainer(keyedBy: NestedKeys.self, forKey: .builtIn)
            try nested.encode(path, forKey: .path)
        }
    }
}

/// A folder in a GitHub repository: `owner/repo`, an optional sub-path and ref.
public struct GitHubLocation: Sendable, Hashable, Codable {
    public var owner: String
    public var repo: String
    /// Folder inside the repo ("" = repo root).
    public var path: String
    /// Branch or tag; nil = the repo's default branch.
    public var ref: String?

    public init(owner: String, repo: String, path: String = "", ref: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.ref = ref
    }

    /// An extension in Raycast's public catalog repo (`raycast/extensions/extensions/<name>`).
    public static func raycastCatalog(_ name: String) -> GitHubLocation {
        GitHubLocation(owner: "raycast", repo: "extensions", path: "extensions/\(name)", ref: "main")
    }

    public var display: String {
        "\(owner)/\(repo)" + (path.isEmpty ? "" : "/\(path)") + (ref.map { "@\($0)" } ?? "")
    }

    public var webURL: URL {
        var url = URL(string: "https://github.com/\(owner)/\(repo)")!
        if !path.isEmpty { url = url.appending(path: "tree/\(ref ?? "HEAD")/\(path)") }
        return url
    }

    /// Understands what people paste:
    /// - `https://github.com/owner/repo`, `…/tree/<ref>/<path>`, `github.com/owner/repo.git`
    /// - `owner/repo`, `owner/repo/sub/path`, `owner/repo@v1.2`, `owner/repo/sub@main`
    /// - a bare name (`google-translate`) → the Raycast catalog, for compatibility.
    public static func parse(_ input: String) -> GitHubLocation? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        for prefix in ["https://", "http://", "www."] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.lowercased().hasPrefix("github.com/") { text.removeFirst("github.com/".count) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        var ref: String?
        if let at = text.lastIndex(of: "@") {
            ref = String(text[text.index(after: at)...])
            text = String(text[..<at])
        }
        let parts = text.split(separator: "/").map(String.init)
        let valid = { (part: String) in part.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
        guard parts.allSatisfy(valid) else { return nil }
        switch parts.count {
        case 0: return nil
        case 1: return ref == nil ? raycastCatalog(parts[0].lowercased()) : nil
        default:
            var rest = Array(parts.dropFirst(2))
            // github.com/owner/repo/tree/<ref>/<path…>
            if rest.first == "tree" || rest.first == "blob", rest.count >= 2 {
                ref = ref ?? rest[1]
                rest = Array(rest.dropFirst(2))
            }
            return GitHubLocation(owner: parts[0], repo: parts[1], path: rest.joined(separator: "/"), ref: ref)
        }
    }
}
