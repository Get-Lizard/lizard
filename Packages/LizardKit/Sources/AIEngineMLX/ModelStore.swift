import Foundation

/// Local model files in the Hugging Face cache (`~/.cache/huggingface/hub`).
public enum ModelStore {
    static var hubDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["HF_HUB_CACHE"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }

    static func directory(for modelID: String) -> URL {
        hubDirectory.appending(path: "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
    }

    /// True when the model's weights are fully on disk: every shard listed in
    /// `model.safetensors.index.json` (one present shard of two used to count as "downloaded",
    /// and the chat then tried to fetch the rest mid-turn), each a real non-empty file, and no
    /// half-finished download left in the cache.
    public static func isDownloaded(_ modelID: String) -> Bool {
        let base = directory(for: modelID)
        let snapshots = base.appending(path: "snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: base.appending(path: "blobs").path)) ?? []
        if blobs.contains(where: { $0.hasSuffix(".incomplete") }) { return false }
        return revisions.contains { revision in
            let folder = snapshots.appending(path: revision)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            guard files.contains("config.json") else { return false }
            return requiredShards(in: folder, files: files).map { shards in
                !shards.isEmpty && shards.allSatisfy { isRealFile(folder.appending(path: $0)) }
            } ?? false
        }
    }

    /// The weight files a snapshot needs: the index's shards, or the single safetensors file.
    static func requiredShards(in folder: URL, files: [String]) -> [String]? {
        if files.contains("model.safetensors.index.json") {
            guard let data = try? Data(contentsOf: folder.appending(path: "model.safetensors.index.json")),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let map = json["weight_map"] as? [String: String]
            else { return nil }
            return Array(Set(map.values)).sorted()
        }
        let single = files.filter { $0.hasSuffix(".safetensors") }
        return single.isEmpty ? nil : single
    }

    /// A symlink that resolves to a non-empty file.
    static func isRealFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.size] as? Int64) ?? 0
        return size > 0
    }

    public static func diskUsageBytes(_ modelID: String) -> Int64 {
        let blobs = directory(for: modelID).appending(path: "blobs")
        guard let enumerator = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return total
    }

    public static func delete(_ modelID: String) throws {
        let directory = directory(for: modelID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

/// Measures a model download from disk: finished blobs in the cache plus in-flight URLSession
/// temp files created since the download began. Independent of the downloader's own progress
/// reporting (which can stay silent for long periods).
final class DiskDownloadMeter: @unchecked Sendable {
    private let modelID: String
    private let startedAt = Date()
    private let lock = NSLock()
    private var expectedTotal: Int64?

    init(modelID: String) {
        self.modelID = modelID
    }

    /// Total download size from the Hugging Face API (fetched once).
    func loadExpectedTotal() async {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelID)?blobs=true"),
            let (data, _) = try? await URLSession.shared.data(from: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let siblings = json["siblings"] as? [[String: Any]]
        else { return }
        let total = siblings.reduce(Int64(0)) { $0 + Int64(($1["size"] as? NSNumber)?.int64Value ?? 0) }
        lock.withLock { expectedTotal = total > 0 ? total : nil }
    }

    func snapshot() -> ModelDownloadProgress? {
        guard let total = lock.withLock({ expectedTotal }) else { return nil }
        let finished = ModelStore.diskUsageBytes(modelID)
        let inFlight = Self.inFlightBytes(since: startedAt)
        let done = min(total, finished + inFlight)
        return ModelDownloadProgress(fraction: Double(done) / Double(total), completedBytes: done, totalBytes: total)
    }

    private static func inFlightBytes(since start: Date) -> Int64 {
        let temp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
        else { return 0 }
        return entries.reduce(Int64(0)) { sum, url in
            guard url.lastPathComponent.hasPrefix("CFNetworkDownload_"),
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                let created = values.creationDate, created >= start.addingTimeInterval(-2)
            else { return sum }
            return sum + Int64(values.fileSize ?? 0)
        }
    }
}
