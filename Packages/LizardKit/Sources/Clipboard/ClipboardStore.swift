import CryptoKit
import Foundation
import LizardCore
import SQLite3

public struct ClipItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case text, url, image, file, color }

    public let id: Int64
    public let kind: Kind
    /// Text, URL string, file path(s) or color; for images, a short description.
    public let text: String
    /// PNG on disk for images.
    public let imagePath: String?
    public let sourceApp: String?
    public let created: Date
    public let pinned: Bool
    public let byteSize: Int
}

public enum ClipboardError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): "Clipboard history database: \(message)" }
    }
}

/// Clipboard history in SQLite with an FTS5 index for search. Duplicates move to the top
/// instead of piling up; old unpinned items expire by count and age.
public actor ClipboardStore {
    public struct Retention: Sendable {
        public var maxItems: Int
        public var maxAge: TimeInterval
        public init(maxItems: Int = 1000, maxAge: TimeInterval = 30 * 24 * 3600) {
            self.maxItems = maxItems
            self.maxAge = maxAge
        }
    }

    nonisolated(unsafe) private var db: OpaquePointer?
    private let imagesDirectory: URL
    public var retention: Retention

    public init(
        databaseURL: URL = AppPaths.applicationSupport.appending(path: "clipboard.sqlite"),
        imagesDirectory: URL = AppPaths.applicationSupport.appending(path: "Clipboard", directoryHint: .isDirectory),
        retention: Retention = Retention()
    ) throws {
        self.imagesDirectory = imagesDirectory
        self.retention = retention
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw ClipboardError.sqlite("can't open") }
        try Self.exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS clips(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT NOT NULL, image_path TEXT,
                source_app TEXT, created REAL NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, byte_size INTEGER NOT NULL, hash TEXT NOT NULL UNIQUE);
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(text, content='clips', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN INSERT INTO clips_fts(clips_fts, rowid, text) VALUES('delete', old.id, old.text); END;
            CREATE TRIGGER IF NOT EXISTS clips_au AFTER UPDATE OF text ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text); END;
            """)
    }

    deinit { sqlite3_close(db) }

    static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw ClipboardError.sqlite(message)
        }
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    public static func hash(kind: ClipItem.Kind, text: String, data: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data(text.utf8))
        if let data { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stores a text-like item (text, url, file paths, color). Returns its id.
    @discardableResult
    public func insert(kind: ClipItem.Kind, text: String, sourceApp: String?, date: Date = .now) throws -> Int64 {
        try insert(kind: kind, text: text, imageData: nil, sourceApp: sourceApp, date: date)
    }

    /// Stores an image as PNG data.
    @discardableResult
    public func insertImage(png: Data, description: String, sourceApp: String?, date: Date = .now) throws -> Int64 {
        try insert(kind: .image, text: description, imageData: png, sourceApp: sourceApp, date: date)
    }

    private func insert(kind: ClipItem.Kind, text: String, imageData: Data?, sourceApp: String?, date: Date) throws -> Int64 {
        let hash = Self.hash(kind: kind, text: text, data: imageData)
        // Duplicate: bump it to now.
        let bump = try prepare("UPDATE clips SET created = ?, source_app = COALESCE(?, source_app) WHERE hash = ? RETURNING id")
        defer { sqlite3_finalize(bump) }
        sqlite3_bind_double(bump, 1, date.timeIntervalSince1970)
        if let sourceApp { sqlite3_bind_text(bump, 2, sourceApp, -1, transient) } else { sqlite3_bind_null(bump, 2) }
        sqlite3_bind_text(bump, 3, hash, -1, transient)
        if sqlite3_step(bump) == SQLITE_ROW { return sqlite3_column_int64(bump, 0) }

        var imagePath: String?
        if let imageData {
            let url = imagesDirectory.appending(path: "\(hash.prefix(24)).png")
            try imageData.write(to: url, options: .atomic)
            imagePath = url.path
        }
        let statement = try prepare("INSERT INTO clips(kind, text, image_path, source_app, created, byte_size, hash) VALUES (?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, text, -1, transient)
        if let imagePath { sqlite3_bind_text(statement, 3, imagePath, -1, transient) } else { sqlite3_bind_null(statement, 3) }
        if let sourceApp { sqlite3_bind_text(statement, 4, sourceApp, -1, transient) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, Int64(imageData?.count ?? text.utf8.count))
        sqlite3_bind_text(statement, 7, hash, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardError.sqlite(String(cString: sqlite3_errmsg(db))) }
        let id = sqlite3_last_insert_rowid(db)
        try prune(now: date)
        return id
    }

    private static let columns = "c.id, c.kind, c.text, c.image_path, c.source_app, c.created, c.pinned, c.byte_size"

    private func rows(_ statement: OpaquePointer?) -> [ClipItem] {
        var items: [ClipItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            items.append(ClipItem(
                id: sqlite3_column_int64(statement, 0), kind: ClipItem.Kind(rawValue: text(1) ?? "text") ?? .text, text: text(2) ?? "",
                imagePath: text(3), sourceApp: text(4), created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                pinned: sqlite3_column_int(statement, 6) != 0, byteSize: Int(sqlite3_column_int64(statement, 7))))
        }
        return items
    }

    /// Pinned first, then newest.
    public func recent(limit: Int = 200) throws -> [ClipItem] {
        let statement = try prepare("SELECT \(Self.columns) FROM clips c ORDER BY c.pinned DESC, c.created DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        return rows(statement)
    }

    /// Full-text search (prefix match on each word).
    public func search(_ query: String, limit: Int = 200) throws -> [ClipItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !words.isEmpty else { return try recent(limit: limit) }
        let statement = try prepare("""
            SELECT \(Self.columns) FROM clips_fts f JOIN clips c ON c.id = f.rowid WHERE clips_fts MATCH ?
            ORDER BY c.pinned DESC, c.created DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, words.joined(separator: " "), -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        return rows(statement)
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        let statement = try prepare("UPDATE clips SET pinned = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    public func delete(_ id: Int64) throws {
        try removeImages(where: "id = \(id)")
        try Self.exec(db, "DELETE FROM clips WHERE id = \(id)")
    }

    public func clear(keepPinned: Bool = true) throws {
        let condition = keepPinned ? "pinned = 0" : "1"
        try removeImages(where: condition)
        try Self.exec(db, "DELETE FROM clips WHERE \(condition)")
    }

    /// Drops unpinned items beyond the count and age limits.
    public func prune(now: Date = .now) throws {
        let cutoff = now.timeIntervalSince1970 - retention.maxAge
        let condition = """
            pinned = 0 AND (created < \(cutoff) OR id NOT IN (SELECT id FROM clips WHERE pinned = 0 ORDER BY created DESC LIMIT \(retention.maxItems)))
            """
        try removeImages(where: condition)
        try Self.exec(db, "DELETE FROM clips WHERE \(condition)")
    }

    private func removeImages(where condition: String) throws {
        let statement = try prepare("SELECT image_path FROM clips WHERE image_path IS NOT NULL AND (\(condition))")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = sqlite3_column_text(statement, 0) { try? FileManager.default.removeItem(atPath: String(cString: path)) }
        }
    }

    public func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM clips")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }
}
