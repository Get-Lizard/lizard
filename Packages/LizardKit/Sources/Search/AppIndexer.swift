import CoreServices
import Foundation

/// An installed application.
public struct AppEntry: Sendable, Hashable, Identifiable {
    public var id: String { path.path }
    public let name: String
    public let bundleIdentifier: String?
    public let path: URL
    /// Extra names to match (file name, display name).
    public let keywords: [String]
}

/// Indexes .app bundles in the usual folders and keeps the list fresh with FSEvents.
public actor AppIndexer {
    public static let defaultRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/Applications"), URL(filePath: "/Applications/Utilities"),
            URL(filePath: "/System/Applications"), URL(filePath: "/System/Applications/Utilities"),
            home.appending(path: "Applications"),
        ]
    }()

    public private(set) var apps: [AppEntry] = []
    private let roots: [URL]
    private var stream: FSEventStreamRef?
    private var continuations: [UUID: AsyncStream<[AppEntry]>.Continuation] = [:]
    private var pending: Task<Void, Never>?

    public init(roots: [URL] = AppIndexer.defaultRoots) {
        self.roots = roots
    }

    @discardableResult
    public func refresh() -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        for root in roots {
            for url in Self.bundles(in: root, depth: 2) {
                let entry = Self.entry(for: url)
                let key = entry.bundleIdentifier ?? entry.path.path
                if seen.insert(key).inserted { result.append(entry) }
            }
        }
        let finder = URL(filePath: "/System/Library/CoreServices/Finder.app")
        if FileManager.default.fileExists(atPath: finder.path) { result.append(Self.entry(for: finder)) }
        apps = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for continuation in continuations.values { continuation.yield(apps) }
        return apps
    }

    /// New lists whenever apps are installed or removed.
    public func updates() -> AsyncStream<[AppEntry]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[AppEntry]>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        startWatching()
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func startWatching() {
        guard stream == nil else { return }
        let paths = roots.map(\.path) as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let indexer = Unmanaged<AppIndexer>.fromOpaque(info).takeUnretainedValue()
            Task { await indexer.scheduleRefresh() }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
        stream = created
    }

    func scheduleRefresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    static func bundles(in root: URL, depth: Int) -> [URL] {
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for child in children {
            if child.pathExtension == "app" {
                found.append(child)
            } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found += bundles(in: child, depth: depth - 1)
            }
        }
        return found
    }

    static func entry(for url: URL) -> AppEntry {
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? [:]
        let base = bundle?.infoDictionary ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent
        let display = (info["CFBundleDisplayName"] as? String) ?? (base["CFBundleDisplayName"] as? String)
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        let keywords = Set([fileName, display, base["CFBundleName"] as? String].compactMap { $0 }).subtracting([name])
        return AppEntry(name: name, bundleIdentifier: bundle?.bundleIdentifier, path: url, keywords: Array(keywords))
    }
}
