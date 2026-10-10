import Foundation
import LizardCore

/// A Markdown note on disk.
public struct Note: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let modified: Date
    public let preview: String
    /// Folder relative to the notes root ("" = top level, "Work/Infra").
    public var folder: String = ""
    public var tags: [String] = []
    public var pinned = false
    /// For snippet notes: the command/code to copy.
    public var snippet: String?
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

    /// All notes in every folder, pinned first then newest. Also refreshes the search index.
    public func list() -> [Note] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var notes: [Note] = []
        var fresh: [URL: String] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            fresh[url] = text.lowercased()
            let metadata = NoteMetadata.parse(text)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            notes.append(Note(
                url: url, title: Self.title(of: metadata.body, fallback: url), modified: modified, preview: Self.preview(of: metadata.body),
                folder: folder(of: url), tags: metadata.tags, pinned: metadata.pinned, snippet: metadata.snippet))
        }
        index = fresh
        return notes.sorted { ($0.pinned ? 1 : 0, $0.modified) > ($1.pinned ? 1 : 0, $1.modified) }
    }

    /// Relative folder of a note ("" for the root).
    public func folder(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard parent.hasPrefix(base) else { return "" }
        return String(parent.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Every folder (relative paths), sorted, including empty ones.
    public func folders() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            result.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func createFolder(_ name: String, in parent: String = "") throws -> String {
        let clean = Self.slug(name)
        let path = parent.isEmpty ? clean : "\(parent)/\(clean)"
        try FileManager.default.createDirectory(at: root.appending(path: path, directoryHint: .isDirectory), withIntermediateDirectories: true)
        return path
    }

    /// Moves a note into a folder (created if needed); returns its new URL.
    public func move(_ url: URL, toFolder folder: String) throws -> URL {
        let directory = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appending(path: url.lastPathComponent)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(counter).md")
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        index[target] = index.removeValue(forKey: url)
        return target
    }

    /// Moves a folder (with its notes) to the Trash.
    public func deleteFolder(_ folder: String) throws {
        guard !folder.isEmpty else { return }
        try FileManager.default.trashItem(at: root.appending(path: folder, directoryHint: .isDirectory), resultingItemURL: nil)
    }

    public func renameFolder(_ folder: String, to name: String) throws -> String {
        let source = root.appending(path: folder, directoryHint: .isDirectory)
        let parent = (folder as NSString).deletingLastPathComponent
        let path = parent.isEmpty ? Self.slug(name) : "\(parent)/\(Self.slug(name))"
        try FileManager.default.moveItem(at: source, to: root.appending(path: path, directoryHint: .isDirectory))
        return path
    }

    /// Rewrites the note's front matter tags.
    public func setTags(_ tags: [String], for url: URL) throws {
        try save(NoteMetadata.updating(read(url), tags: tags), to: url)
    }

    public func setPinned(_ pinned: Bool, for url: URL) throws {
        try save(NoteMetadata.updating(read(url), pinned: pinned), to: url)
    }

    public func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public func save(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        index[url] = text.lowercased()
    }

    /// Creates `<slug>.md` (unique) starting with a heading.
    public func create(title: String, folder: String = "") throws -> URL {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Self.slug(clean.isEmpty ? "Untitled" : clean)
        let directory = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: "\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base)-\(counter).md")
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
        let target = url.deletingLastPathComponent().appending(path: "\(Self.slug(title)).md")
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
            return words.allSatisfy { word in
                if word.hasPrefix("#") { return note.tags.contains(String(word.dropFirst())) }
                return text.contains(word) || note.title.lowercased().contains(word) || note.folder.lowercased().contains(word)
            }
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
        // Watches the root folder (new/renamed files); edits inside subfolders are picked up on the next list().
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
