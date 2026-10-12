import Foundation

/// A published Lizard release, read from GitHub's "latest release" API.
public struct AppRelease: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let pageURL: URL
    /// The signed, notarized DMG.
    public let dmgURL: URL?

    public init(version: String, notes: String, pageURL: URL, dmgURL: URL?) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
    }

    public static let latestAPI = URL(string: "https://api.github.com/repos/Get-Lizard/lizard/releases/latest")!

    /// Parses `/releases/latest`; nil for drafts, prereleases or anything malformed.
    public static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        return AppRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: json["body"] as? String ?? "",
            pageURL: page, dmgURL: dmg.flatMap(URL.init(string:)))
    }

    /// Numeric, part by part: "0.1.10" > "0.1.9", "1.0" == "1.0.0". Suffixes ("-beta") are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
