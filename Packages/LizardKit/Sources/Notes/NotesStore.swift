import Foundation
import LizardCore

/// A Markdown note on disk.
public struct Note: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let modified: Date
    public let preview: String
}

/// Plain `.md` files in a folder (default ~/Documents/Notes), editable by any other tool.
public actor NotesStore {
    public let root: URL
    private var index: [URL: String] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// All notes, newest first. Also refreshes the search index.
    public func list() -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var notes: [Note] = []
        var fresh: [URL: String] = [:]
        for url in files where url.pathExtension.lowercased() == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            fresh[url] = text.lowercased()
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            notes.append(Note(url: url, title: Self.title(of: text, fallback: url), modified: modified, preview: Self.preview(of: text)))
        }
        index = fresh
        return notes.sorted { $0.modified > $1.modified }
    }

    public func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public func save(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        index[url] = text.lowercased()
    }

    /// Creates `<slug>.md` (unique) starting with a heading.
    public func create(title: String) throws -> URL {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Self.slug(clean.isEmpty ? "Untitled" : clean)
        var url = root.appending(path: "\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appending(path: "\(base)-\(counter).md")
            counter += 1
        }
        try save("# \(clean.isEmpty ? "Untitled" : clean)\n\n", to: url)
        return url
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        index[url] = nil
    }

    public func rename(_ url: URL, to title: String) throws -> URL {
        let target = root.appending(path: "\(Self.slug(title)).md")
        guard target != url else { return url }
        try FileManager.default.moveItem(at: url, to: target)
        index[target] = index.removeValue(forKey: url)
        return target
    }

    /// Notes whose text contains every word of `query`.
    public func search(_ query: String) -> [Note] {
        let all = list()
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { note in
            let text = index[note.url] ?? ""
            return words.allSatisfy { text.contains($0) || note.title.lowercased().contains($0) }
        }
    }

    /// Fires when files in the folder change (also edits from other apps).
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.drop(id) } }
        startWatching()
        return stream
    }

    private func drop(_ id: UUID) { continuations[id] = nil }

    private func startWatching() {
        guard watcher == nil else { return }
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.notify() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func notify() { for continuation in continuations.values { continuation.yield() } }

    static func title(of text: String, fallback url: URL) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func preview(of text: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }.map { String($0.prefix(120)) } ?? ""
    }

    public static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : String(collapsed.prefix(80))
    }
}
