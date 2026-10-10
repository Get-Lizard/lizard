import CryptoKit
import Foundation

/// Where a piece of knowledge comes from.
public enum KnowledgeSource: String, Sendable, Codable, CaseIterable, Identifiable {
    case note, workLog, clipboard, chat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .note: "Notes"
        case .workLog: "Work Log"
        case .clipboard: "Clipboard"
        case .chat: "AI Chats"
        }
    }

    public var symbol: String {
        switch self {
        case .note: "note.text"
        case .workLog: "list.bullet.clipboard"
        case .clipboard: "doc.on.clipboard"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }
}

/// Something to index: a note, a day of work log, a clipboard item, a chat.
public struct KnowledgeDocument: Sendable, Hashable {
    /// Stable within its source (file path, "2026-10-10", clip id, chat id).
    public let id: String
    public let source: KnowledgeSource
    public let title: String
    public let text: String
    public let modified: Date
    /// How to open it (a file path, a URL, a clip id…); interpreted by the app.
    public let location: String?

    public init(id: String, source: KnowledgeSource, title: String, text: String, modified: Date, location: String? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.text = text
        self.modified = modified
        self.location = location
    }

    /// Unique across sources.
    public var key: String { "\(source.rawValue):\(id)" }

    /// Content hash: unchanged documents are never re-embedded.
    public var contentHash: String {
        let digest = SHA256.hash(data: Data((title + "\u{1F}" + text).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// A passage of a document, the unit that's embedded and retrieved.
public struct KnowledgeChunk: Sendable, Hashable {
    public let ordinal: Int
    public let text: String
    /// The heading the passage sits under, if any ("## Deploy").
    public let heading: String?
}

/// One search result.
public struct KnowledgeHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(documentKey)#\(ordinal)" }
    public let documentKey: String
    public let source: KnowledgeSource
    public let title: String
    public let location: String?
    public let modified: Date
    public let ordinal: Int
    public let text: String
    public let heading: String?
    /// Fused rank score (higher is better).
    public let score: Double
    /// Cosine similarity of the passage to the query (0 when only keywords matched).
    public let similarity: Double

    public init(
        documentKey: String, source: KnowledgeSource, title: String, location: String?, modified: Date, ordinal: Int,
        text: String, heading: String?, score: Double, similarity: Double
    ) {
        self.documentKey = documentKey
        self.source = source
        self.title = title
        self.location = location
        self.modified = modified
        self.ordinal = ordinal
        self.text = text
        self.heading = heading
        self.score = score
        self.similarity = similarity
    }
}
