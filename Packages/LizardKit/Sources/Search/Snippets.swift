import Foundation
import LizardCore

/// Reusable text: paste it from the launcher, or type its keyword anywhere to expand it.
/// Same JSON shape as Raycast's snippet export (`[{name, text, keyword?}]`), so files move both ways.
public struct Snippet: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String
    /// Typed anywhere (e.g. ";sig"), it's replaced by the snippet.
    public var keyword: String?
    /// nil for snippets saved before these were kept (and for imports).
    public var created: Date?
    public var modified: Date?

    public init(id: UUID = UUID(), name: String, text: String, keyword: String? = nil, created: Date? = nil, modified: Date? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = keyword
        self.created = created
        self.modified = modified
    }

    // MARK: Kinds

    /// What the Search Snippets type filter sorts by.
    public enum ContentType: String, CaseIterable, Sendable {
        case text = "Text"
        case link = "Link"
        case dynamic = "Dynamic"
        case arguments = "With Arguments"
    }

    /// The snippet's own kind: a single URL is a link; placeholders make it dynamic.
    public var contentType: ContentType {
        if !arguments.isEmpty { return .arguments }
        if Self.placeholderMatches(in: text).isEmpty == false { return .dynamic }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), url.scheme != nil, url.host() != nil { return .link }
        return .text
    }

    // MARK: Arguments

    /// A value asked for when the snippet is used: `{argument name="ticket" default="1" options="a, b"}`.
    /// The same name used twice is asked once; each unnamed `{argument}` is its own.
    public struct Argument: Sendable, Hashable, Identifiable {
        /// What `expand(arguments:)` is keyed by: the name, or "#1", "#2"… for unnamed ones.
        public var key: String
        public var name: String?
        public var defaultValue: String?
        public var options: [String]

        public var id: String { key }
        public var label: String { name ?? "Argument" }
    }

    /// The snippet's arguments in the order they first appear.
    public var arguments: [Argument] { Self.arguments(in: text) }

    public static func arguments(in template: String) -> [Argument] {
        let source = template as NSString
        var result: [Argument] = []
        var unnamed = 0
        for match in placeholderMatches(in: template) where source.substring(with: match.range(at: 1)).lowercased() == "argument" {
            let argument = argument(from: parseAttributes(source.substring(with: match.range(at: 2))), unnamed: &unnamed)
            if !result.contains(where: { $0.key == argument.key }) { result.append(argument) }
        }
        return result
    }

    private static func argument(from attributes: [String: String], unnamed: inout Int) -> Argument {
        let options = attributes["options"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        let name = attributes["name"].flatMap { $0.isEmpty ? nil : $0 }
        let key: String
        if let name {
            key = name
        } else {
            unnamed += 1
            key = "#\(unnamed)"
        }
        return Argument(key: key, name: name, defaultValue: attributes["default"] ?? options.first, options: options)
    }

    // MARK: Raycast files

    /// Reads a Raycast "Export Snippets" file. Raycast placeholders that mean the same as ours are
    /// kept; others pass through untouched.
    public static func fromRaycastExport(_ data: Data) -> [Snippet] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, let text = item["text"] as? String, item["link"] == nil else { return nil }
            let keyword = (item["keyword"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Snippet(name: name, text: text, keyword: keyword)
        }
    }

    /// Writes the Raycast-compatible JSON (Raycast's "Import Snippets" reads it).
    public static func raycastExport(_ snippets: [Snippet]) throws -> Data {
        let items: [[String: String]] = snippets.map { snippet in
            var item = ["name": snippet.name, "text": snippet.text]
            if let keyword = snippet.keyword { item["keyword"] = keyword }
            return item
        }
        return try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Placeholders

    public struct Expansion: Sendable, Equatable {
        public var text: String
        /// Characters from the end where the caret should land (`{cursor}`), nil for the end.
        public var cursorFromEnd: Int?
        /// Where each argument's value landed (character offsets in `text`), for previews.
        public var argumentRanges: [ArgumentRange] = []
    }

    public struct ArgumentRange: Sendable, Equatable {
        public var key: String
        public var range: Range<Int>
    }

    /// The placeholders a snippet can use, for editors' insert menus (Raycast's syntax).
    public static let placeholders: [(token: String, meaning: String)] = [
        (#"{argument name="ticket"}"#, "asked for when you use it; add default=\"…\" or options=\"a, b\""),
        ("{clipboard}", "the text you copied"),
        ("{clipboard offset=1}", "the copy before that (from clipboard history)"),
        ("{selection}", "text selected in the app you're in"),
        ("{cursor}", "where the caret lands after pasting"),
        ("{date}", "today's date"),
        ("{time}", "the current time"),
        ("{datetime}", "date and time"),
        ("{day}", "the weekday"),
        ("{uuid}", "a new random ID"),
        (#"{date format="yyyy-MM-dd"}"#, "a date in your own format"),
        (#"{date offset="+1d"}"#, "relative to now: m, h, d, w, M, y (e.g. +2d -3h)"),
        (#"{snippet name="Signature"}"#, "another snippet's text"),
        ("{clipboard | trim | uppercase}", "modifiers: uppercase, lowercase, trim, percent-encode, json-stringify, raw"),
    ]

    /// Fills Raycast's dynamic placeholders: `{argument}` (from `arguments`, keyed by
    /// `Argument.key`; missing ones use their default), `{clipboard}` (`offset=N` reaches back through
    /// clipboard history), `{selection}`, `{date}`/`{time}`/`{datetime}`/`{day}` with `format="…"`
    /// and `offset="+1d -2h"`, `{uuid}`, `{cursor}`, `{snippet name="…"}` (not recursive), each
    /// optionally followed by `| uppercase | lowercase | trim | percent-encode | json-stringify | raw`.
    /// Unknown placeholders are left as typed.
    public static func expand(
        _ template: String, clipboard: String? = nil, selection: String? = nil, now: Date = .now,
        calendar: Calendar = .current, locale: Locale = .current, snippets: [Snippet] = [],
        clipboardHistory: (Int) -> String? = { _ in nil }, arguments: [String: String] = [:]
    ) -> Expansion {
        let source = template as NSString
        var output = ""
        var cursorIndex: Int?
        var argumentRanges: [ArgumentRange] = []
        var unnamed = 0
        var last = 0
        for match in placeholderMatches(in: template) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let name = source.substring(with: match.range(at: 1)).lowercased()
            let attributes = parseAttributes(source.substring(with: match.range(at: 2)))
            let modifiers = source.substring(with: match.range(at: 3)).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            let value: String
            switch name {
            case "argument":
                let argument = argument(from: attributes, unnamed: &unnamed)
                let filled = apply(modifiers, to: arguments[argument.key] ?? argument.defaultValue ?? "")
                argumentRanges.append(ArgumentRange(key: argument.key, range: output.count..<(output.count + filled.count)))
                output += filled
                continue
            case "clipboard":
                let back = attributes["offset"].flatMap { Int($0) } ?? 0
                value = back > 0 ? (clipboardHistory(back) ?? "") : (clipboard ?? "")
            case "selection": value = selection ?? ""
            case "uuid": value = UUID().uuidString
            case "cursor":
                if cursorIndex == nil { cursorIndex = output.count }
                continue
            case "snippet":
                let wanted = attributes["name"]?.lowercased() ?? ""
                guard let text = snippets.first(where: { $0.name.lowercased() == wanted })?.text else {
                    // Unknown name (or a reference inside an included snippet): leave it as typed.
                    output += source.substring(with: match.range)
                    continue
                }
                // One level only: the included snippet is expanded without other snippets.
                value = expand(text, clipboard: clipboard, selection: selection, now: now, calendar: calendar, locale: locale, clipboardHistory: clipboardHistory, arguments: arguments).text
            default:
                let date = attributes["offset"].flatMap { offset($0, from: now, calendar: calendar) } ?? now
                value = format(date, kind: name, custom: attributes["format"], calendar: calendar, locale: locale)
            }
            output += apply(modifiers, to: value)
        }
        output += source.substring(from: last)
        return Expansion(text: output, cursorFromEnd: cursorIndex.map { output.count - $0 }, argumentRanges: argumentRanges)
    }

    private static func placeholderMatches(in template: String) -> [NSTextCheckingResult] {
        let pattern = #"\{(argument|clipboard|selection|date|time|datetime|day|uuid|cursor|snippet)((?:\s+[a-z]+=(?:"[^"]*"|[^\s|}"]+))*)\s*((?:\|\s*[a-z-]+\s*)*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length))
    }

    static func apply(_ modifiers: [String], to value: String) -> String {
        modifiers.reduce(value) { text, modifier in
            switch modifier {
            case "uppercase": text.uppercased()
            case "lowercase": text.lowercased()
            case "trim": text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode": text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
            case "json-stringify":
                (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? text
            default: text  // "raw" and anything unknown: as is
            }
        }
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        // name="quoted value" or name=bare (Raycast accepts `offset=+1h`).
        let regex = try? NSRegularExpression(pattern: #"([a-z]+)=(?:"([^"]*)"|([^\s"]+))"#)
        let source = text as NSString
        for match in regex?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            let quoted = match.range(at: 2), bare = match.range(at: 3)
            let value = quoted.location != NSNotFound ? source.substring(with: quoted) : source.substring(with: bare)
            result[source.substring(with: match.range(at: 1)).lowercased()] = value
        }
        return result
    }

    /// "+1d", "-2w", "+3M", "+1y", "+2h", "-30m"; several may be combined ("+1d +2h").
    static func offset(_ text: String, from date: Date, calendar: Calendar) -> Date? {
        let regex = try? NSRegularExpression(pattern: #"([+-]?\d+)\s*([mhdwMy])"#)
        let source = text as NSString
        var result = date
        var matched = false
        for match in regex?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            guard let amount = Int(source.substring(with: match.range(at: 1))) else { continue }
            let component: Calendar.Component = switch source.substring(with: match.range(at: 2)) {
            case "m": .minute
            case "h": .hour
            case "d": .day
            case "w": .weekOfYear
            case "M": .month
            default: .year
            }
            if let moved = calendar.date(byAdding: component, value: amount, to: result) {
                result = moved
                matched = true
            }
        }
        return matched ? result : nil
    }

    private static func format(_ date: Date, kind: String, custom: String?, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if let custom {
            formatter.dateFormat = custom
            return formatter.string(from: date)
        }
        switch kind {
        case "time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case "datetime":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        case "day":
            formatter.dateFormat = "EEEE"
        default:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}

/// Watches typed characters for a snippet keyword. Pure logic: the app feeds it keystrokes and
/// expands what it returns.
public struct SnippetKeywordMatcher: Sendable {
    private var typed = ""
    private var keywords: [(keyword: String, id: UUID)] = []
    private let capacity = 64

    public init() {}

    public mutating func update(_ snippets: [Snippet]) {
        // Longest first, so ";sig2" wins over ";sig" when both match.
        keywords = snippets.compactMap { snippet in snippet.keyword.flatMap { $0.isEmpty ? nil : ($0, snippet.id) } }
            .sorted { $0.keyword.count > $1.keyword.count }
    }

    public var isEmpty: Bool { keywords.isEmpty }

    /// Feed typed text; returns the snippet whose keyword was just completed (and clears the buffer).
    public mutating func typed(_ text: String) -> (id: UUID, keyword: String)? {
        typed += text
        if typed.count > capacity { typed.removeFirst(typed.count - capacity) }
        guard let hit = keywords.first(where: { typed.hasSuffix($0.keyword) }) else { return nil }
        typed = ""
        return hit
    }

    /// Backspace removes the last character; anything that moves the caret starts over.
    public mutating func deleteBackward() {
        if !typed.isEmpty { typed.removeLast() }
    }

    public mutating func reset() {
        typed = ""
    }
}

/// How often a snippet was pasted or copied, and when last.
public struct SnippetUsage: Codable, Sendable, Hashable {
    public var count = 0
    public var lastUsed: Date?
}

/// Snippets saved as JSON in Application Support. Usage lives in its own file so pasting a
/// snippet doesn't count as editing it (iCloud sync compares the snippets file).
public actor SnippetStore {
    private let url: URL
    private let usageURL: URL
    public private(set) var snippets: [Snippet]
    public private(set) var usage: [UUID: SnippetUsage]

    public init(url: URL = AppPaths.applicationSupport.appending(path: "snippets.json")) {
        self.url = url
        usageURL = url.deletingLastPathComponent().appending(path: "snippet-usage.json")
        snippets = ResilientFile.read(url) { try JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        usage = ResilientFile.read(usageURL) { try JSONDecoder().decode([UUID: SnippetUsage].self, from: $0) } ?? [:]
    }

    public var modified: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    /// Saves an edit (or a new snippet), stamping when it was created and changed.
    public func save(_ snippet: Snippet, now: Date = .now) {
        var snippet = snippet
        snippet.modified = now
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippet.created = snippet.created ?? snippets[index].created
            snippets[index] = snippet
        } else {
            snippet.created = snippet.created ?? now
            snippets.append(snippet)
        }
        persist()
    }

    public func recordUse(_ id: UUID, now: Date = .now) {
        var entry = usage[id] ?? SnippetUsage()
        entry.count += 1
        entry.lastUsed = now
        usage[id] = entry
        if let data = try? JSONEncoder().encode(usage) { try? ResilientFile.write(data, to: usageURL) }
    }

    public func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    public func replaceAll(_ newSnippets: [Snippet]) {
        snippets = newSnippets
        persist()
    }

    /// Adds snippets that aren't here yet (same name or same keyword counts as here). Returns how many.
    public func merge(_ newSnippets: [Snippet]) -> Int {
        var names = Set(snippets.map { $0.name.lowercased() })
        var keywords = Set(snippets.compactMap(\.keyword))
        var added: [Snippet] = []
        for snippet in newSnippets where !names.contains(snippet.name.lowercased()) && !(snippet.keyword.map(keywords.contains) ?? false) {
            added.append(snippet)
            names.insert(snippet.name.lowercased())
            if let keyword = snippet.keyword { keywords.insert(keyword) }
        }
        guard !added.isEmpty else { return 0 }
        snippets += added
        persist()
        return added.count
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) { try? ResilientFile.write(data, to: url) }
    }
}
