import Accelerate
import Foundation
import LizardCore
import SQLite3

public enum KnowledgeError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): "Search index: \(message)" }
    }
}

/// Local semantic index: passages + vectors in SQLite, with an FTS5 table for keyword matches.
///
/// Search is hybrid — vector similarity and BM25 keyword rank fused with reciprocal-rank
/// fusion — so exact terms ("ECONNRESET", ticket ids) and paraphrases ("that redis timeout
/// thing") both find the right passage. Vectors are scanned in memory (thousands of passages
/// take a few milliseconds), so there's no ANN index to maintain.
public actor KnowledgeIndex {
    public struct Stats: Sendable, Equatable {
        public var documents: [KnowledgeSource: Int] = [:]
        public var chunks = 0
        public var embedder: String?
        public init() {}
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    nonisolated(unsafe) private var db: OpaquePointer?
    /// chunk id → (vectors, document key); loaded lazily, kept in sync. Several vectors per chunk
    /// for sentence models (one per sentence).
    private var vectors: [Int64: (vectors: [[Float]], document: String)]?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = AppPaths.applicationSupport.appending(path: "knowledge.sqlite")) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw KnowledgeError.sqlite("can't open \(url.path)") }
        try Self.exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS documents(
                key TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT NOT NULL, location TEXT, modified REAL NOT NULL, hash TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT, doc_key TEXT NOT NULL, ordinal INTEGER NOT NULL, heading TEXT, text TEXT NOT NULL, vector BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc_key);
            CREATE TABLE IF NOT EXISTS chunk_vectors(chunk_id INTEGER NOT NULL, vector BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS chunk_vectors_chunk ON chunk_vectors(chunk_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(title, text, tokenize='unicode61 remove_diacritics 2');
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: SQLite helpers

    private func exec(_ sql: String) throws { try Self.exec(db, sql) }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw KnowledgeError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw KnowledgeError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(statement, index, text, -1, transient) } else { sqlite3_bind_null(statement, index) }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func meta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        return sqlite3_step(statement) == SQLITE_ROW ? column(statement, 0) : nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        bind(statement, 2, value)
        sqlite3_step(statement)
    }

    // MARK: Sync

    /// Brings the index in line with `documents` for the given sources: removes documents that
    /// disappeared, embeds new and changed ones. Unchanged documents cost nothing.
    @discardableResult
    public func sync(
        _ documents: [KnowledgeDocument], sources: Set<KnowledgeSource>, embedder: any Embedder,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Int {
        if try meta("embedder") != embedder.identifier {
            try exec("DELETE FROM chunks; DELETE FROM chunk_vectors; DELETE FROM chunks_fts; DELETE FROM documents;")
            try setMeta("embedder", embedder.identifier)
            vectors = nil
        }
        var existing: [String: String] = [:]
        let select = try prepare("SELECT key, hash, source FROM documents")
        while sqlite3_step(select) == SQLITE_ROW {
            guard let source = column(select, 2).flatMap(KnowledgeSource.init(rawValue:)), sources.contains(source) else { continue }
            existing[column(select, 0) ?? ""] = column(select, 1) ?? ""
        }
        sqlite3_finalize(select)

        let incoming = Dictionary(documents.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in existing.keys where incoming[key] == nil { try remove(key) }
        let changed = documents.filter { existing[$0.key] != $0.contentHash }
        var done = 0
        progress?(Progress(done: 0, total: changed.count))
        for document in changed {
            try Task.checkCancellation()
            try await index(document, embedder: embedder)
            done += 1
            progress?(Progress(done: done, total: changed.count))
        }
        return changed.count
    }

    private func remove(_ key: String) throws {
        let ids = try prepare("SELECT id FROM chunks WHERE doc_key = ?")
        bind(ids, 1, key)
        var removed: [Int64] = []
        while sqlite3_step(ids) == SQLITE_ROW { removed.append(sqlite3_column_int64(ids, 0)) }
        sqlite3_finalize(ids)
        for id in removed {
            try exec("DELETE FROM chunks_fts WHERE rowid = \(id)")
            try exec("DELETE FROM chunk_vectors WHERE chunk_id = \(id)")
        }
        for (table, column) in [("chunks", "doc_key"), ("documents", "key")] {
            let statement = try prepare("DELETE FROM \(table) WHERE \(column) = ?")
            bind(statement, 1, key)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        for id in removed { vectors?[id] = nil }
    }

    private func index(_ document: KnowledgeDocument, embedder: any Embedder) async throws {
        let chunks = TextChunker.chunks(for: document.text, targetCharacters: embedder.preferredChunkCharacters, overlap: embedder.preferredChunkCharacters / 6)
        // What to embed per chunk: the whole passage (with its title and heading), or, for sentence
        // models, the title plus each sentence on its own.
        let perChunk: [[String]] = chunks.map { chunk in
            let context = [document.title, chunk.heading].compactMap { $0 }.joined(separator: " — ")
            guard embedder.embedsSentences else { return [context + "\n" + chunk.text] }
            return [context] + Self.sentences(in: chunk.text)
        }
        let flat = perChunk.flatMap { $0 }
        var flatVectors: [[Float]] = []
        for start in stride(from: 0, to: flat.count, by: 16) {
            flatVectors += try await embedder.embed(Array(flat[start..<min(start + 16, flat.count)]), kind: .passage)
        }
        var embeddings: [[[Float]]] = []
        var cursor = 0
        for texts in perChunk {
            embeddings.append(Array(flatVectors[cursor..<min(cursor + texts.count, flatVectors.count)]))
            cursor += texts.count
        }
        try remove(document.key)
        try exec("BEGIN")
        do {
            let insertDocument = try prepare("INSERT INTO documents(key, source, title, location, modified, hash) VALUES (?,?,?,?,?,?)")
            bind(insertDocument, 1, document.key)
            bind(insertDocument, 2, document.source.rawValue)
            bind(insertDocument, 3, document.title)
            bind(insertDocument, 4, document.location)
            sqlite3_bind_double(insertDocument, 5, document.modified.timeIntervalSince1970)
            bind(insertDocument, 6, document.contentHash)
            sqlite3_step(insertDocument)
            sqlite3_finalize(insertDocument)
            for (chunk, chunkVectors) in zip(chunks, embeddings) {
                guard let vector = chunkVectors.first else { continue }
                let insert = try prepare("INSERT INTO chunks(doc_key, ordinal, heading, text, vector) VALUES (?,?,?,?,?)")
                bind(insert, 1, document.key)
                sqlite3_bind_int(insert, 2, Int32(chunk.ordinal))
                bind(insert, 3, chunk.heading)
                bind(insert, 4, chunk.text)
                sqlite3_bind_blob(insert, 5, vector, Int32(vector.count * MemoryLayout<Float>.size), transient)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw KnowledgeError.sqlite(String(cString: sqlite3_errmsg(db))) }
                sqlite3_finalize(insert)
                let id = sqlite3_last_insert_rowid(db)
                let fts = try prepare("INSERT INTO chunks_fts(rowid, title, text) VALUES (?,?,?)")
                sqlite3_bind_int64(fts, 1, id)
                bind(fts, 2, [document.title, chunk.heading].compactMap { $0 }.joined(separator: " "))
                bind(fts, 3, chunk.text)
                sqlite3_step(fts)
                sqlite3_finalize(fts)
                if chunkVectors.count > 1 {
                    for extra in chunkVectors {
                        let row = try prepare("INSERT INTO chunk_vectors(chunk_id, vector) VALUES (?,?)")
                        sqlite3_bind_int64(row, 1, id)
                        sqlite3_bind_blob(row, 2, extra, Int32(extra.count * MemoryLayout<Float>.size), transient)
                        sqlite3_step(row)
                        sqlite3_finalize(row)
                    }
                }
                vectors?[id] = (chunkVectors, document.key)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Search

    private func loadVectors() throws -> [Int64: (vectors: [[Float]], document: String)] {
        if let vectors { return vectors }
        func floats(_ statement: OpaquePointer?, _ column: Int32) -> [Float]? {
            let count = Int(sqlite3_column_bytes(statement, column)) / MemoryLayout<Float>.size
            guard count > 0, let blob = sqlite3_column_blob(statement, column) else { return nil }
            return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
        }
        var loaded: [Int64: (vectors: [[Float]], document: String)] = [:]
        let statement = try prepare("SELECT id, doc_key, vector FROM chunks")
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let vector = floats(statement, 2) else { continue }
            loaded[sqlite3_column_int64(statement, 0)] = ([vector], column(statement, 1) ?? "")
        }
        sqlite3_finalize(statement)
        var extra: [Int64: [[Float]]] = [:]
        let rows = try prepare("SELECT chunk_id, vector FROM chunk_vectors")
        while sqlite3_step(rows) == SQLITE_ROW {
            if let vector = floats(rows, 1) { extra[sqlite3_column_int64(rows, 0), default: []].append(vector) }
        }
        sqlite3_finalize(rows)
        for (id, list) in extra where loaded[id] != nil { loaded[id]!.vectors = list }
        vectors = loaded
        return loaded
    }

    /// Sentences (and list items / lines) worth embedding on their own.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.isEmpty { continue }
            var current = ""
            for character in trimmed {
                current.append(character)
                if ".!?".contains(character), current.count > 20 {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if rest.count >= 8 { result.append(rest) }
        }
        return Array(result.prefix(24))
    }

    /// Hybrid search. `perDocument` caps passages from the same document so one long note
    /// doesn't crowd out everything else.
    public func search(
        _ query: String, embedder: any Embedder, sources: Set<KnowledgeSource> = Set(KnowledgeSource.allCases),
        limit: Int = 8, perDocument: Int = 2
    ) async throws -> [KnowledgeHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let queryVector = try await embedder.embed([trimmed], kind: .query).first ?? []

        // Vector ranking.
        var similarities: [Int64: Float] = [:]
        var vectorRanked: [(Int64, Float)] = []
        if !queryVector.isEmpty {
            for (id, entry) in try loadVectors() {
                var best: Float = -1
                for vector in entry.vectors where vector.count == queryVector.count {
                    var score: Float = 0
                    vDSP_dotpr(vector, 1, queryVector, 1, &score, vDSP_Length(queryVector.count))
                    best = max(best, score)
                }
                if best > -1 { similarities[id] = best }
            }
            vectorRanked = similarities.sorted { $0.value > $1.value }.prefix(60).map { ($0.key, $0.value) }
        }

        // Keyword ranking (BM25), prefix-matching each meaningful word.
        var keywordScores: [Int64: Double] = [:]
        let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 && !Self.stopWords.contains(String($0)) }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        if !words.isEmpty {
            let statement = try prepare("SELECT rowid, bm25(chunks_fts) FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT 60")
            bind(statement, 1, words.joined(separator: " OR "))
            while sqlite3_step(statement) == SQLITE_ROW {
                // SQLite's bm25 is negative; more negative = better.
                keywordScores[sqlite3_column_int64(statement, 0)] = -sqlite3_column_double(statement, 1)
            }
            sqlite3_finalize(statement)
        }

        // Blend: meaning (cosine, rescaled over the candidates) + keyword strength (BM25 relative to
        // the best keyword match). Rank-only fusion ignored *how much* better a keyword match was.
        let candidates = Set(vectorRanked.map(\.0)).union(keywordScores.keys)
        let bestKeyword = keywordScores.values.max() ?? 0
        let maxSim = Double(vectorRanked.first?.1 ?? 0)
        var fused: [Int64: Double] = [:]
        for id in candidates {
            let similarity = Double(similarities[id] ?? 0)
            // Meaning relative to the best match (keeps paraphrase ordering, scale-free across models).
            let meaning = maxSim > 0 ? max(0, similarity) / maxSim : 0
            let keyword = bestKeyword > 0 ? (keywordScores[id] ?? 0) / bestKeyword : 0
            // Weak meaning matches only count when keywords back them up.
            guard similarity > 0.2 || keyword > 0 else { continue }
            fused[id] = 0.55 * meaning + 0.45 * keyword
        }
        let ordered = fused.sorted { $0.value > $1.value }

        var hits: [KnowledgeHit] = []
        var perDocumentCount: [String: Int] = [:]
        let fetch = try prepare("""
            SELECT c.doc_key, c.ordinal, c.heading, c.text, d.source, d.title, d.location, d.modified
            FROM chunks c JOIN documents d ON d.key = c.doc_key WHERE c.id = ?
            """)
        defer { sqlite3_finalize(fetch) }
        for (id, score) in ordered {
            sqlite3_reset(fetch)
            sqlite3_bind_int64(fetch, 1, id)
            guard sqlite3_step(fetch) == SQLITE_ROW, let key = column(fetch, 0),
                let source = column(fetch, 4).flatMap(KnowledgeSource.init(rawValue:)), sources.contains(source)
            else { continue }
            guard perDocumentCount[key, default: 0] < perDocument else { continue }
            perDocumentCount[key, default: 0] += 1
            hits.append(KnowledgeHit(
                documentKey: key, source: source, title: column(fetch, 5) ?? "", location: column(fetch, 6),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(fetch, 7)), ordinal: Int(sqlite3_column_int(fetch, 1)),
                text: column(fetch, 3) ?? "", heading: column(fetch, 2), score: score, similarity: Double(similarities[id] ?? 0)))
            if hits.count == limit { break }
        }
        return hits
    }

    /// Words that carry no meaning for keyword matching (English + Portuguese basics).
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "it", "i", "my", "me", "we", "you", "how", "what",
        "did", "do", "does", "was", "were", "be", "that", "this", "when", "where", "why", "which", "at", "by", "from", "as", "about",
        "o", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "e", "em", "no", "na", "que", "como", "eu", "para", "por", "com",
    ]

    public func stats() throws -> Stats {
        var stats = Stats()
        let statement = try prepare("SELECT source, COUNT(*) FROM documents GROUP BY source")
        while sqlite3_step(statement) == SQLITE_ROW {
            if let source = column(statement, 0).flatMap(KnowledgeSource.init(rawValue:)) { stats.documents[source] = Int(sqlite3_column_int(statement, 1)) }
        }
        sqlite3_finalize(statement)
        let count = try prepare("SELECT COUNT(*) FROM chunks")
        if sqlite3_step(count) == SQLITE_ROW { stats.chunks = Int(sqlite3_column_int(count, 0)) }
        sqlite3_finalize(count)
        stats.embedder = try meta("embedder")
        return stats
    }

    /// Forgets everything (the next sync rebuilds it).
    public func reset() throws {
        try exec("DELETE FROM chunks; DELETE FROM chunk_vectors; DELETE FROM chunks_fts; DELETE FROM documents; DELETE FROM meta;")
        vectors = nil
    }
}
