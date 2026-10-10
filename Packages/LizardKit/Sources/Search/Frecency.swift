import Foundation
import LizardCore
import Synchronization

/// Remembers what you open and how recently, so frequent picks rise to the top.
/// Each use adds 1, decaying with a 7-day half-life.
public final class Frecency: Sendable {
    struct Record: Codable {
        var score: Double
        var lastUsed: Date
    }

    public static let halfLife: TimeInterval = 7 * 24 * 3600
    private let records: Mutex<[String: Record]>
    private let url: URL

    public init(url: URL = AppPaths.applicationSupport.appending(path: "frecency.json")) {
        self.url = url
        records = Mutex(ResilientFile.read(url) { try JSONDecoder().decode([String: Record].self, from: $0) } ?? [:])
    }

    static func decayed(_ record: Record, now: Date) -> Double {
        record.score * pow(0.5, now.timeIntervalSince(record.lastUsed) / halfLife)
    }

    public func record(_ id: String, now: Date = .now) {
        let snapshot = records.withLock { records -> [String: Record] in
            let current = records[id].map { Self.decayed($0, now: now) } ?? 0
            records[id] = Record(score: current + 1, lastUsed: now)
            return records
        }
        if let data = try? JSONEncoder().encode(snapshot) { try? ResilientFile.write(data, to: url) }
    }

    /// 0 for never-used items; grows with use, fades with time.
    public func boost(for id: String, now: Date = .now) -> Double {
        records.withLock { records in records[id].map { Self.decayed($0, now: now) } ?? 0 }
    }
}
