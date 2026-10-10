import Foundation
import LizardCore

/// A URL template opened with the launcher's text: "https://github.com/search?q={query}".
public struct Quicklink: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var template: String
    /// Optional short keyword ("gh") to trigger it directly.
    public var keyword: String?
    /// SF Symbol name for the row.
    public var symbol: String

    public init(id: UUID = UUID(), name: String, template: String, keyword: String? = nil, symbol: String = "link") {
        self.id = id
        self.name = name
        self.template = template
        self.keyword = keyword
        self.symbol = symbol
    }

    public var needsQuery: Bool { template.contains("{query}") }

    /// Fills `{query}`, `{clipboard}` and `{selection}`. Web URLs get percent-encoded values;
    /// other schemes (file paths, vscode://) get them raw.
    public func resolve(query: String, clipboard: String? = nil, selection: String? = nil) -> URL? {
        let isWeb = template.lowercased().hasPrefix("http")
        func encode(_ value: String) -> String {
            guard isWeb else { return value }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        var text = template
        text = text.replacingOccurrences(of: "{query}", with: encode(query))
        text = text.replacingOccurrences(of: "{clipboard}", with: encode(clipboard ?? ""))
        text = text.replacingOccurrences(of: "{selection}", with: encode(selection ?? query))
        if !isWeb, text.hasPrefix("~") { text = (text as NSString).expandingTildeInPath }
        if text.hasPrefix("/") { return URL(filePath: text) }
        return URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text)
    }

    public static let defaults: [Quicklink] = [
        Quicklink(name: "Search GitHub", template: "https://github.com/search?q={query}&type=repositories", keyword: "gh", symbol: "chevron.left.forwardslash.chevron.right"),
        Quicklink(name: "Search Google", template: "https://www.google.com/search?q={query}", keyword: "g", symbol: "magnifyingglass"),
        Quicklink(name: "Search Stack Overflow", template: "https://stackoverflow.com/search?q={query}", keyword: "so", symbol: "text.bubble"),
        Quicklink(name: "Search MDN", template: "https://developer.mozilla.org/en-US/search?q={query}", keyword: "mdn", symbol: "book"),
        Quicklink(name: "Search npm", template: "https://www.npmjs.com/search?q={query}", keyword: "npm", symbol: "shippingbox"),
        Quicklink(name: "Apple Developer Docs", template: "https://developer.apple.com/search/?q={query}", keyword: "apple", symbol: "apple.logo"),
        Quicklink(name: "Open in VS Code", template: "vscode://file/{query}", keyword: "code", symbol: "curlybraces"),
    ]
}

/// Quicklinks saved as JSON in Application Support.
public actor QuicklinkStore {
    private let url: URL
    public private(set) var links: [Quicklink]

    public init(url: URL = AppPaths.applicationSupport.appending(path: "quicklinks.json")) {
        self.url = url
        links = ResilientFile.read(url) { try JSONDecoder().decode([Quicklink].self, from: $0) } ?? Quicklink.defaults
    }

    public func save(_ link: Quicklink) {
        if let index = links.firstIndex(where: { $0.id == link.id }) { links[index] = link } else { links.append(link) }
        persist()
    }

    public func delete(_ id: UUID) {
        links.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(links) { try? ResilientFile.write(data, to: url) }
    }
}
