import Foundation
import LizardCore

/// A URL template opened with the launcher's text: "https://github.com/search?q={query}".
public struct Quicklink: Codable, Sendable, Hashable, Identifiable {
    /// Converts a Raycast quicklinks export (`[{name, link, openWith?}]`, `{Query}` placeholders).
    public static func fromRaycastExport(_ data: Data) -> [Quicklink] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, var link = item["link"] as? String else { return nil }
            for (raycast, lizard) in [("{Query}", "{query}"), ("{query}", "{query}"), ("{Clipboard Text}", "{clipboard}"), ("{clipboard}", "{clipboard}"), ("{Selected Text}", "{selection}"), ("{selection}", "{selection}")] {
                link = link.replacingOccurrences(of: raycast, with: lizard)
            }
            // `{argument name="x"}` → the typed query.
            link = link.replacingOccurrences(of: #"\{argument[^}]*\}"#, with: "{query}", options: .regularExpression)
            let openWith = (item["openWith"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Quicklink(name: name, template: link, symbol: link.hasPrefix("http") ? "link" : "arrow.up.forward.app", openWith: openWith)
        }
    }

    public var id: UUID
    public var name: String
    public var template: String
    /// Optional short keyword ("gh") to trigger it directly.
    public var keyword: String?
    /// SF Symbol name for the row.
    public var symbol: String
    /// App to open it with: a bundle identifier, an app path, or an app name (Raycast exports
    /// names). nil = the system default for the link (your default browser for web links).
    public var openWith: String?

    public init(id: UUID = UUID(), name: String, template: String, keyword: String? = nil, symbol: String = "link", openWith: String? = nil) {
        self.id = id
        self.name = name
        self.template = template
        self.keyword = keyword
        self.symbol = symbol
        self.openWith = openWith
    }

    /// A starting point from something typed or pasted: "github.com/x" → https://github.com/x,
    /// named after the site. nil when the text doesn't look like a link.
    public static func draft(from text: String) -> Quicklink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let hasScheme = trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
        guard hasScheme || trimmed.range(of: #"^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$"#, options: .regularExpression) != nil else { return nil }
        let template = hasScheme ? trimmed : "https://" + trimmed
        guard let url = URL(string: template) else { return nil }
        let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        let site = host.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Link"
        return Quicklink(name: url.scheme?.hasPrefix("http") == true ? site : trimmed, template: template, symbol: "link")
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
        // One pass over the template: a value that itself contains "{clipboard}" (typed or
        // copied) must not be expanded again, which sequential replacements would do.
        let values = ["{query}": query, "{clipboard}": clipboard ?? "", "{selection}": selection ?? query]
        var text = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            text += rest[..<open]
            if let (placeholder, value) = values.first(where: { rest[open...].hasPrefix($0.key) }) {
                text += encode(value)
                rest = rest[rest.index(open, offsetBy: placeholder.count)...]
            } else {
                text.append("{")
                rest = rest[rest.index(after: open)...]
            }
        }
        text += rest
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

    /// Replaces every quicklink (restore, iCloud sync, Raycast import).
    public func replaceAll(_ newLinks: [Quicklink]) {
        links = newLinks
        persist()
    }

    /// Adds links whose template isn't already present; returns how many were added.
    @discardableResult
    /// Adds links that aren't here yet (same URL, or same name, counts as here: Raycast's
    /// "Search Google" shouldn't sit next to Lizard's own). Returns how many were added.
    public func merge(_ newLinks: [Quicklink]) -> Int {
        var templates = Set(links.map(\.template))
        var names = Set(links.map { $0.name.lowercased() })
        var added: [Quicklink] = []
        for link in newLinks where !templates.contains(link.template) && !names.contains(link.name.lowercased()) {
            added.append(link)
            templates.insert(link.template)
            names.insert(link.name.lowercased())
        }
        guard !added.isEmpty else { return 0 }
        links += added
        persist()
        return added.count
    }

    /// Notified after every change (iCloud sync listens).
    public var onChange: (@Sendable () -> Void)?

    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(links) { try? ResilientFile.write(data, to: url) }
        onChange?()
    }
}
